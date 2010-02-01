% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License.  You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd_auth).
-include("couch_db.hrl").

-export([default_authentication_handler/1,special_test_authentication_handler/1]).
-export([cookie_authentication_handler/1]).
-export([null_authentication_handler/1]).
-export([cookie_auth_header/2]).
-export([handle_session_req/1]).
-export([ensure_users_db_exists/1, get_user/1]).

-import(couch_httpd, [header_value/2, send_json/2,send_json/4, send_method_not_allowed/2]).

special_test_authentication_handler(Req) ->
    case header_value(Req, "WWW-Authenticate") of
    "X-Couch-Test-Auth " ++ NamePass ->
        % NamePass is a colon separated string: "joe schmoe:a password".
        [Name, Pass] = re:split(NamePass, ":", [{return, list}]),
        case {Name, Pass} of
        {"Jan Lehnardt", "apple"} -> ok;
        {"Christopher Lenz", "dog food"} -> ok;
        {"Noah Slater", "biggiesmalls endian"} -> ok;
        {"Chris Anderson", "mp3"} -> ok;
        {"Damien Katz", "pecan pie"} -> ok;
        {_, _} ->
            throw({unauthorized, <<"Name or password is incorrect.">>})
        end,
        Req#httpd{user_ctx=#user_ctx{name=?l2b(Name)}};
    _ ->
        % No X-Couch-Test-Auth credentials sent, give admin access so the
        % previous authentication can be restored after the test
        Req#httpd{user_ctx=#user_ctx{roles=[<<"_admin">>]}}
    end.

basic_name_pw(Req) ->
    AuthorizationHeader = header_value(Req, "Authorization"),
    case AuthorizationHeader of
    "Basic " ++ Base64Value ->
        case string:tokens(?b2l(couch_util:decodeBase64(Base64Value)),":") of
        ["_", "_"] ->
            % special name and pass to be logged out
            nil;
        [User, Pass] ->
            {User, Pass};
        [User] ->
            {User, ""};
        _ ->
            nil
        end;
    _ ->
        nil
    end.

default_authentication_handler(Req) ->
    case basic_name_pw(Req) of
    {User, Pass} ->
        case get_user(?l2b(User)) of
            nil ->
                throw({unauthorized, <<"Name or password is incorrect.">>});
            UserProps ->
                UserSalt = proplists:get_value(<<"salt">>, UserProps, <<>>),
                PasswordHash = hash_password(?l2b(Pass), UserSalt),
                ExpectedHash = proplists:get_value(<<"password_sha">>, UserProps, nil),
                case couch_util:verify(ExpectedHash, PasswordHash) of
                    true ->
                        Req#httpd{user_ctx=#user_ctx{
                            name=?l2b(User),
                            roles=proplists:get_value(<<"roles">>, UserProps, [])
                        }};
                    _Else ->
                        throw({unauthorized, <<"Name or password is incorrect.">>})
                end
        end;
    nil ->
        case couch_server:has_admins() of
        true ->
            Req;
        false ->
            case couch_config:get("couch_httpd_auth", "require_valid_user", "false") of
                "true" -> Req;
                % If no admins, and no user required, then everyone is admin!
                % Yay, admin party!
                _ -> Req#httpd{user_ctx=#user_ctx{roles=[<<"_admin">>]}}
            end
        end
    end.

null_authentication_handler(Req) ->
    Req#httpd{user_ctx=#user_ctx{roles=[<<"_admin">>]}}.

% maybe we can use hovercraft to simplify running this view query
% rename to get_user_from_users_db
get_user(UserName) ->
    case couch_config:get("admins", ?b2l(UserName)) of
    "-hashed-" ++ HashedPwdAndSalt ->
        % the name is an admin, now check to see if there is a user doc
        % which has a matching name, salt, and password_sha
        [HashedPwd, Salt] = string:tokens(HashedPwdAndSalt, ","),
        case get_user_props_from_db(UserName) of
            nil ->        
                [{<<"roles">>, [<<"_admin">>]},
                  {<<"salt">>, ?l2b(Salt)},
                  {<<"password_sha">>, ?l2b(HashedPwd)}];
            UserProps when is_list(UserProps) ->
                DocRoles = proplists:get_value(<<"roles">>, UserProps),
                [{<<"roles">>, [<<"_admin">> | DocRoles]},
                  {<<"salt">>, ?l2b(Salt)},
                  {<<"password_sha">>, ?l2b(HashedPwd)}]
        end;
    _Else ->
        get_user_props_from_db(UserName)
    end.

get_user_props_from_db(UserName) ->
    DbName = couch_config:get("couch_httpd_auth", "authentication_db"),
    {ok, Db} = ensure_users_db_exists(?l2b(DbName)),
    DocId = <<"org.couchdb.user:", UserName/binary>>,
    try couch_httpd_db:couch_doc_open(Db, DocId, nil, [conflicts]) of
        #doc{meta=Meta}=Doc ->
            %  check here for conflict state and throw error if conflicted
            case proplists:get_value(conflicts,Meta,[]) of
                [] -> 
                    {DocProps} = couch_query_servers:json_doc(Doc),
                    case proplists:get_value(<<"type">>, DocProps) of
                        <<"user">> ->
                            DocProps;
                        _Else -> 
                            ?LOG_ERROR("Invalid user doc. Id: ~p",[DocId]),
                            nil
                    end;
                _Else ->
                    throw({unauthorized, <<"User document conflict must be resolved before login.">>})
            end
    catch
        throw:_Throw ->
            nil
    end.

% this should handle creating the ddoc
ensure_users_db_exists(DbName) ->
    case couch_db:open(DbName, [{user_ctx, #user_ctx{roles=[<<"_admin">>]}}]) of
    {ok, Db} ->
        ensure_auth_ddoc_exists(Db, <<"_design/_auth">>),
        {ok, Db};
    _Error -> 
        {ok, Db} = couch_db:create(DbName, [{user_ctx, #user_ctx{roles=[<<"_admin">>]}}]),
        ensure_auth_ddoc_exists(Db, <<"_design/_auth">>),
        {ok, Db}
    end.
    
ensure_auth_ddoc_exists(Db, DDocId) -> 
    try couch_httpd_db:couch_doc_open(Db, DDocId, nil, []) of
        _Foo -> ok
    catch 
        _:_Error -> 
            % create the design document
            {ok, AuthDesign} = auth_design_doc(DDocId),
            {ok, _Rev} = couch_db:update_doc(Db, AuthDesign, []),
            ok
    end.

% add the validation function here
auth_design_doc(DocId) ->
    DocProps = [
        {<<"_id">>, DocId},
        {<<"language">>,<<"javascript">>},
        {
            <<"validate_doc_update">>,
            <<"function(newDoc, oldDoc, userCtx) {
                if ((oldDoc || newDoc).type != 'user') {
                    throw({forbidden : 'doc.type must be user'});
                } // we only validate user docs for now
                if (newDoc._deleted === true) {
                    // allow deletes by admins and matching users 
                    // without checking the other fields
                    if ((userCtx.roles.indexOf('_admin') != -1) || (userCtx.name == oldDoc.name)) {
                        return;
                    } else {
                        throw({forbidden : 'Only admins may delete other user docs.'});
                    }
                }
                if (!newDoc.name) {
                    throw({forbidden : 'doc.name is required'});
                }
                if (!(newDoc.roles && (typeof newDoc.roles.length != 'undefined') )) {
                    throw({forbidden : 'doc.roles must be an array'});
                }
                if (newDoc._id != 'org.couchdb.user:'+newDoc.name) {
                    throw({forbidden : 'Docid must be of the form org.couchdb.user:name'});
                }
                if (oldDoc) { // validate all updates
                    if (oldDoc.name != newDoc.name) {
                      throw({forbidden : 'Usernames may not be changed.'});
                    }
                }
                if (newDoc.password_sha && !newDoc.salt) {
                    throw({forbidden : 'Users with password_sha must have a salt. See /_utils/script/couch.js for example code.'});
                }
                if (userCtx.roles.indexOf('_admin') == -1) { // not an admin
                    if (oldDoc) { // validate non-admin updates
                        if (userCtx.name != newDoc.name) {
                          throw({forbidden : 'You may only update your own user document.'});
                        }
                        // validate role updates
                        var oldRoles = oldDoc.roles.sort();
                        var newRoles = newDoc.roles.sort();
                        if (oldRoles.length != newRoles.length) {
                            throw({forbidden : 'Only _admin may edit roles'});
                        }
                        for (var i=0; i < oldRoles.length; i++) {
                            if (oldRoles[i] != newRoles[i]) {
                                throw({forbidden : 'Only _admin may edit roles'});
                            }
                        };
                    } else if (newDoc.roles.length > 0) {
                        throw({forbidden : 'Only _admin may set roles'});
                    }
                }
                // no system roles in users db
                for (var i=0; i < newDoc.roles.length; i++) {
                    if (newDoc.roles[i][0] == '_') {
                        throw({forbidden : 'No system roles (starting with underscore) in users db.'});
                    }
                };
                // no system names as names
                if (newDoc.name[0] == '_') {
                    throw({forbidden : 'Username may not start with underscore.'});
                }
            }">>
        }],
    {ok, couch_doc:from_json_obj({DocProps})}.

cookie_authentication_handler(#httpd{mochi_req=MochiReq}=Req) ->
    case MochiReq:get_cookie_value("AuthSession") of
    undefined -> Req;
    [] -> Req;
    Cookie -> 
        [User, TimeStr | HashParts] = try
            AuthSession = couch_util:decodeBase64Url(Cookie),
            [_A, _B | _Cs] = string:tokens(?b2l(AuthSession), ":")
        catch
            _:_Error ->
                Reason = <<"Malformed AuthSession cookie. Please clear your cookies.">>,
                throw({bad_request, Reason})
        end,
        % Verify expiry and hash
        {NowMS, NowS, _} = erlang:now(),
        CurrentTime = NowMS * 1000000 + NowS,
        case couch_config:get("couch_httpd_auth", "secret", nil) of
        nil -> 
            ?LOG_ERROR("cookie auth secret is not set",[]),
            Req;
        SecretStr ->
            Secret = ?l2b(SecretStr),
            case get_user(?l2b(User)) of
            nil -> Req;
            UserProps ->
                UserSalt = proplists:get_value(<<"salt">>, UserProps, <<"">>),
                FullSecret = <<Secret/binary, UserSalt/binary>>,
                ExpectedHash = crypto:sha_mac(FullSecret, User ++ ":" ++ TimeStr),
                Hash = ?l2b(string:join(HashParts, ":")),
                Timeout = to_int(couch_config:get("couch_httpd_auth", "timeout", 600)),
                ?LOG_DEBUG("timeout ~p", [Timeout]),
                case (catch erlang:list_to_integer(TimeStr, 16)) of
                    TimeStamp when CurrentTime < TimeStamp + Timeout ->
                        case couch_util:verify(ExpectedHash, Hash) of
                            true ->
                                TimeLeft = TimeStamp + Timeout - CurrentTime,
                                ?LOG_DEBUG("Successful cookie auth as: ~p", [User]),
                                Req#httpd{user_ctx=#user_ctx{
                                    name=?l2b(User),
                                    roles=proplists:get_value(<<"roles">>, UserProps, [])
                                }, auth={FullSecret, TimeLeft < Timeout*0.9}};
                            _Else ->
                                Req
                        end;
                    _Else ->
                        Req
                end
            end
        end
    end.

cookie_auth_header(#httpd{user_ctx=#user_ctx{name=null}}, _Headers) -> [];
cookie_auth_header(#httpd{user_ctx=#user_ctx{name=User}, auth={Secret, true}}, Headers) ->
    % Note: we only set the AuthSession cookie if:
    %  * a valid AuthSession cookie has been received
    %  * we are outside a 10% timeout window
    %  * and if an AuthSession cookie hasn't already been set e.g. by a login
    %    or logout handler.
    % The login and logout handlers need to set the AuthSession cookie
    % themselves.
    CookieHeader = proplists:get_value("Set-Cookie", Headers, ""),
    Cookies = mochiweb_cookies:parse_cookie(CookieHeader),
    AuthSession = proplists:get_value("AuthSession", Cookies),
    if AuthSession == undefined ->
        {NowMS, NowS, _} = erlang:now(),
        TimeStamp = NowMS * 1000000 + NowS,
        [cookie_auth_cookie(?b2l(User), Secret, TimeStamp)];
    true ->
        []
    end;
cookie_auth_header(_Req, _Headers) -> [].

cookie_auth_cookie(User, Secret, TimeStamp) ->
    SessionData = User ++ ":" ++ erlang:integer_to_list(TimeStamp, 16),
    Hash = crypto:sha_mac(Secret, SessionData),
    mochiweb_cookies:cookie("AuthSession",
        couch_util:encodeBase64Url(SessionData ++ ":" ++ ?b2l(Hash)),
        [{path, "/"}, {http_only, true}]). % TODO add {secure, true} when SSL is detected

hash_password(Password, Salt) ->
    ?l2b(couch_util:to_hex(crypto:sha(<<Password/binary, Salt/binary>>))).

ensure_cookie_auth_secret() ->
    case couch_config:get("couch_httpd_auth", "secret", nil) of
        nil ->
            NewSecret = ?b2l(couch_uuids:random()),
            couch_config:set("couch_httpd_auth", "secret", NewSecret),
            NewSecret;
        Secret -> Secret
    end.

% session handlers
% Login handler with user db
% TODO this should also allow a JSON POST
handle_session_req(#httpd{method='POST', mochi_req=MochiReq}=Req) ->
    ReqBody = MochiReq:recv_body(),
    Form = case MochiReq:get_primary_header_value("content-type") of
        "application/x-www-form-urlencoded" ++ _ ->
            mochiweb_util:parse_qs(ReqBody);
        _ ->
            []
    end,
    UserName = ?l2b(proplists:get_value("name", Form, "")),
    Password = ?l2b(proplists:get_value("password", Form, "")),
    ?LOG_DEBUG("Attempt Login: ~s",[UserName]),
    User = case get_user(UserName) of
        nil -> [];
        Result -> Result
    end,
    UserSalt = proplists:get_value(<<"salt">>, User, <<>>),
    PasswordHash = hash_password(Password, UserSalt),
    ExpectedHash = proplists:get_value(<<"password_sha">>, User, nil),
    case couch_util:verify(ExpectedHash, PasswordHash) of
        true ->
            % setup the session cookie
            Secret = ?l2b(ensure_cookie_auth_secret()),
            {NowMS, NowS, _} = erlang:now(),
            CurrentTime = NowMS * 1000000 + NowS,
            Cookie = cookie_auth_cookie(?b2l(UserName), <<Secret/binary, UserSalt/binary>>, CurrentTime),
            % TODO document the "next" feature in Futon
            {Code, Headers} = case couch_httpd:qs_value(Req, "next", nil) of
                nil ->
                    {200, [Cookie]};
                Redirect ->
                    {302, [Cookie, {"Location", couch_httpd:absolute_uri(Req, Redirect)}]}
            end,
            send_json(Req#httpd{req_body=ReqBody}, Code, Headers,
                {[
                    {ok, true},
                    {name, proplists:get_value(<<"name">>, User, null)},
                    {roles, proplists:get_value(<<"roles">>, User, [])}
                ]});
        _Else ->
            % clear the session
            Cookie = mochiweb_cookies:cookie("AuthSession", "", [{path, "/"}, {http_only, true}]),
            send_json(Req, 401, [Cookie], {[{error, <<"unauthorized">>},{reason, <<"Name or password is incorrect.">>}]})
    end;
% get user info
% GET /_session
handle_session_req(#httpd{method='GET', user_ctx=UserCtx}=Req) ->
    Name = UserCtx#user_ctx.name,
    ForceLogin = couch_httpd:qs_value(Req, "basic", "false"),
    case {Name, ForceLogin} of
        {null, "true"} ->
            throw({unauthorized, <<"Please login.">>});
        {Name, _} ->
            send_json(Req, {[
                % remove this ok
                {ok, true},
                {<<"userCtx">>, {[
                    {name, Name},
                    {roles, UserCtx#user_ctx.roles}
                ]}},
                {info, {[
                    {authentication_db, ?l2b(couch_config:get("couch_httpd_auth", "authentication_db"))},
                    {authentication_handlers, [auth_name(H) || H <- couch_httpd:make_fun_spec_strs(
                            couch_config:get("httpd", "authentication_handlers"))]}
                ] ++ maybe_value(authenticated, UserCtx#user_ctx.handler, fun(Handler) -> 
                        auth_name(?b2l(Handler))
                    end)}}
            ]})
    end;
% logout by deleting the session
handle_session_req(#httpd{method='DELETE'}=Req) ->
    Cookie = mochiweb_cookies:cookie("AuthSession", "", [{path, "/"}, {http_only, true}]),
    {Code, Headers} = case couch_httpd:qs_value(Req, "next", nil) of
        nil ->
            {200, [Cookie]};
        Redirect ->
            {302, [Cookie, {"Location", couch_httpd:absolute_uri(Req, Redirect)}]}
    end,
    send_json(Req, Code, Headers, {[{ok, true}]});
handle_session_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD,POST,DELETE").

maybe_value(_Key, undefined, _Fun) -> [];
maybe_value(Key, Else, Fun) -> 
    [{Key, Fun(Else)}].

auth_name(String) when is_list(String) ->
    [_,_,_,_,_,Name|_] = re:split(String, "[\\W_]", [{return, list}]),
    ?l2b(Name).

to_int(Value) when is_binary(Value) ->
    to_int(?b2l(Value)); 
to_int(Value) when is_list(Value) ->
    list_to_integer(Value);
to_int(Value) when is_integer(Value) ->
    Value.
