% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd_handler).
-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_httpd/include/couch_httpd.hrl").

-export([
    start_link/0,
    start_link/1,
    start_link/2,
    stop/0
]).

-export([
    handle_request/1,
    handle_request_int/1
]).

-export([
    authenticate_request/3
]).


-record(delayed_resp, {
    start_fun,
    req,
    code,
    headers,
    first_chunk,
    resp=nil
}).

start_link() ->
    start_link(http).
start_link(http) ->
    Port = config:get("chttpd", "port", "5984"),
    start_link(?MODULE, [{port, Port}]);

start_link(https) ->
    Port = config:get("ssl", "port", "6984"),
    {ok, Ciphers} = couch_util:parse_term(config:get("ssl", "ciphers", undefined)),
    {ok, Versions} = couch_util:parse_term(config:get("ssl", "tls_versions", undefined)),
    {ok, SecureRenegotiate} = couch_util:parse_term(config:get("ssl", "secure_renegotiate", undefined)),
    ServerOpts0 =
        [{cacertfile, config:get("ssl", "cacert_file", undefined)},
         {keyfile, config:get("ssl", "key_file", undefined)},
         {certfile, config:get("ssl", "cert_file", undefined)},
         {password, config:get("ssl", "password", undefined)},
         {secure_renegotiate, SecureRenegotiate},
         {versions, Versions},
         {ciphers, Ciphers}],

    case (couch_util:get_value(keyfile, ServerOpts0) == undefined orelse
        couch_util:get_value(certfile, ServerOpts0) == undefined) of
        true ->
            io:format("SSL enabled but PEM certificates are missing.", []),
            throw({error, missing_certs});
        false ->
            ok
    end,

    ServerOpts = [Opt || {_, V}=Opt <- ServerOpts0, V /= undefined],

    ClientOpts = case config:get("ssl", "verify_ssl_certificates", "false") of
        "false" ->
            [];
        "true" ->
            FailIfNoPeerCert = case config:get("ssl", "fail_if_no_peer_cert", "false") of
            "false" -> false;
            "true" -> true
            end,
            [{depth, list_to_integer(config:get("ssl",
                "ssl_certificate_max_depth", "1"))},
             {fail_if_no_peer_cert, FailIfNoPeerCert},
             {verify, verify_peer}] ++
            case config:get("ssl", "verify_fun", undefined) of
                undefined -> [];
                SpecStr ->
                    [{verify_fun, couch_httpd:make_arity_3_fun(SpecStr)}]
            end
    end,
    SslOpts = ServerOpts ++ ClientOpts,

    Options =
        [{port, Port},
         {ssl, true},
         {ssl_opts, SslOpts}],
    start_link(https, Options).

start_link(Name, Options) ->
    IP = case config:get("chttpd", "bind_address", "any") of
             "any" -> any;
             Else -> Else
         end,
    ok = couch_httpd:validate_bind_address(IP),

    Options1 = Options ++ [
        {loop, fun ?MODULE:handle_request/1},
        {name, Name},
        {ip, IP}
    ],
    ServerOptsCfg = config:get("chttpd", "server_options", "[]"),
    {ok, ServerOpts} = couch_util:parse_term(ServerOptsCfg),
    Options2 = lists:keymerge(1, lists:sort(Options1), lists:sort(ServerOpts)),
    case mochiweb_http:start(Options2) of
    {ok, Pid} ->
        {ok, Pid};
    {error, Reason} ->
        io:format("Failure to start Mochiweb: ~s~n", [Reason]),
        {error, Reason}
    end.

stop() ->
    catch mochiweb_http:stop(https),
    mochiweb_http:stop(?MODULE).

handle_request(MochiReq0) ->
    erlang:put(?REWRITE_COUNT, 0),
    MochiReq = couch_httpd_vhost:dispatch_host(MochiReq0),
    handle_request_int(MochiReq).

handle_request_int(MochiReq) ->
    Begin = os:timestamp(),
    case config:get("chttpd", "socket_options") of
    undefined ->
        ok;
    SocketOptsCfg ->
        {ok, SocketOpts} = couch_util:parse_term(SocketOptsCfg),
        ok = mochiweb_socket:setopts(MochiReq:get(socket), SocketOpts)
    end,

    % for the path, use the raw path with the query string and fragment
    % removed, but URL quoting left intact
    RawUri = MochiReq:get(raw_path),
    {"/" ++ Path, _, _} = mochiweb_util:urlsplit_path(RawUri),

    % get requested path
    RequestedPath = case MochiReq:get_header_value("x-couchdb-vhost-path") of
        undefined ->
            case MochiReq:get_header_value("x-couchdb-requested-path") of
                undefined -> RawUri;
                R -> R
            end;
        P -> P
    end,

    Peer = MochiReq:get(peer),

    Method1 =
    case MochiReq:get(method) of
        % already an atom
        Meth when is_atom(Meth) -> Meth;

        % Non standard HTTP verbs aren't atoms (COPY, MOVE etc) so convert when
        % possible (if any module references the atom, then it's existing).
        Meth -> couch_util:to_existing_atom(Meth)
    end,
    increment_method_stats(Method1),

    % allow broken HTTP clients to fake a full method vocabulary with an X-HTTP-METHOD-OVERRIDE header
    MethodOverride = MochiReq:get_primary_header_value("X-HTTP-Method-Override"),
    Method2 = case lists:member(MethodOverride, ["GET", "HEAD", "POST", "PUT", "DELETE", "TRACE", "CONNECT", "COPY"]) of
    true ->
        couch_log:notice("MethodOverride: ~s (real method was ~s)", [MethodOverride, Method1]),
        case Method1 of
        'POST' -> couch_util:to_existing_atom(MethodOverride);
        _ ->
            % Ignore X-HTTP-Method-Override when the original verb isn't POST.
            % I'd like to send a 406 error to the client, but that'd require a nasty refactor.
            % throw({not_acceptable, <<"X-HTTP-Method-Override may only be used with POST requests.">>})
            Method1
        end;
    _ -> Method1
    end,

    % alias HEAD to GET as mochiweb takes care of stripping the body
    Method = case Method2 of
        'HEAD' -> 'GET';
        Other -> Other
    end,

    Nonce = couch_util:to_hex(crypto:rand_bytes(5)),

    HttpReq0 = #httpd{
        mochi_req = MochiReq,
        begin_ts = Begin,
        peer = Peer,
        original_method = Method1,
        nonce = Nonce,
        method = Method,
        path_parts = [list_to_binary(couch_httpd:unquote(Part))
                || Part <- string:tokens(Path, "/")],
        requested_path_parts = [?l2b(couch_httpd:unquote(Part))
                || Part <- string:tokens(RequestedPath, "/")]
    },

    % put small token on heap to keep requests synced to backend calls
    erlang:put(nonce, Nonce),

    % suppress duplicate log
    erlang:put(dont_log_request, true),

    {HttpReq2, Response} = case before_request(HttpReq0) of
        {ok, HttpReq1} ->
            process_request(HttpReq1);
        {error, Response0} ->
            {HttpReq0, Response0}
    end,

    {Status, Code, Reason, Resp} = split_response(Response),

    HttpResp = #httpd_resp{
        code = Code,
        status = Status,
        response = Resp,
        nonce = HttpReq2#httpd.nonce,
        reason = Reason
    },

    case after_request(HttpReq2, HttpResp) of
        #httpd_resp{status = ok, response = Resp} ->
            {ok, Resp};
        #httpd_resp{status = aborted, reason = Reason} ->
            couch_log:error("Response abnormally terminated: ~p", [Reason]),
            exit(normal)
    end.

before_request(HttpReq) ->
    try
        couch_httpd_plugin:before_request(HttpReq)
    catch Tag:Error ->
        {error, catch_error(HttpReq, Tag, Error)}
    end.

after_request(HttpReq, HttpResp0) ->
    {ok, HttpResp1} =
        try
            couch_httpd_plugin:after_request(HttpReq, HttpResp0)
        catch _Tag:Error ->
            Stack = erlang:get_stacktrace(),
            couch_httpd:send_error(HttpReq, {Error, nil, Stack}),
            {ok, HttpResp0#httpd_resp{status = aborted}}
        end,
    HttpResp2 = update_stats(HttpReq, HttpResp1),
    maybe_log(HttpReq, HttpResp2),
    HttpResp2.

process_request(#httpd{mochi_req = MochiReq} = HttpReq) ->
    HandlerKey =
        case HttpReq#httpd.path_parts of
            [] -> <<>>;
            [Key|_] -> ?l2b(couch_httpd:quote(Key))
        end,

    RawUri = MochiReq:get(raw_path),

    try
        couch_httpd:validate_host(HttpReq),
        check_request_uri_length(RawUri),
        case couch_httpd_cors:maybe_handle_preflight_request(HttpReq) of
        not_preflight ->
            case couch_httpd_auth_plugin:authenticate(HttpReq, fun authenticate_request/1) of
            #httpd{} = Req ->
                HandlerFun = couch_httpd_handlers:url_handler(
                    HandlerKey, fun chttpd_db:handle_request/1),
                AuthorizedReq = couch_httpd_auth_plugin:authorize(possibly_hack(Req),
                    fun chttpd_auth_request:authorize_request/1),
                {AuthorizedReq, HandlerFun(AuthorizedReq)};
            Response ->
                {HttpReq, Response}
            end;
        Response ->
            {HttpReq, Response}
        end
    catch Tag:Error ->
        {HttpReq, catch_error(HttpReq, Tag, Error)}
    end.

catch_error(_HttpReq, throw, {http_head_abort, Resp}) ->
    {ok, Resp};
catch_error(_HttpReq, throw, {http_abort, Resp, Reason}) ->
    {aborted, Resp, Reason};
catch_error(HttpReq, throw, {invalid_json, _}) ->
    couch_httpd:send_error(HttpReq, {bad_request, "invalid UTF-8 JSON"});
catch_error(HttpReq, exit, {mochiweb_recv_error, E}) ->
    #httpd{
        mochi_req = MochiReq,
        peer = Peer,
        original_method = Method
    } = HttpReq,
    couch_log:notice("mochiweb_recv_error for ~s - ~p ~s - ~p", [
        Peer,
        Method,
        MochiReq:get(raw_path),
        E]),
    exit(normal);
catch_error(HttpReq, exit, {uri_too_long, _}) ->
    couch_httpd:send_error(HttpReq, request_uri_too_long);
catch_error(HttpReq, exit, {body_too_large, _}) ->
    couch_httpd:send_error(HttpReq, request_entity_too_large);
catch_error(HttpReq, throw, Error) ->
    couch_httpd:send_error(HttpReq, Error);
catch_error(HttpReq, error, database_does_not_exist) ->
    couch_httpd:send_error(HttpReq, database_does_not_exist);
catch_error(HttpReq, Tag, Error) ->
    Stack = erlang:get_stacktrace(),
    % TODO improve logging and metrics collection for client disconnects
    case {Tag, Error, Stack} of
        {exit, normal, [{mochiweb_request, send, _, _} | _]} ->
            exit(normal); % Client disconnect (R15+)
        _Else ->
            couch_httpd:send_error(HttpReq, {Error, nil, Stack})
    end.

split_response({ok, #delayed_resp{resp=Resp}}) ->
    {ok, Resp:get(code), undefined, Resp};
split_response({ok, Resp}) ->
    {ok, Resp:get(code), undefined, Resp};
split_response({aborted, Resp, AbortReason}) ->
    {aborted, Resp:get(code), AbortReason, Resp}.

update_stats(HttpReq, #httpd_resp{end_ts = undefined} = Res) ->
    update_stats(HttpReq, Res#httpd_resp{end_ts = os:timestamp()});
update_stats(#httpd{begin_ts = BeginTime}, #httpd_resp{} = Res) ->
    #httpd_resp{status = Status, end_ts = EndTime} = Res,
    RequestTime = timer:now_diff(EndTime, BeginTime) / 1000,
    couch_stats:update_histogram([couchdb, request_time], RequestTime),
    case Status of
        ok ->
            couch_stats:increment_counter([couchdb, httpd, requests]);
        aborted ->
            couch_stats:increment_counter([couchdb, httpd, aborted_requests])
    end,
    Res.

maybe_log(#httpd{} = HttpReq, #httpd_resp{should_log = true} = HttpResp) ->
    #httpd{
        mochi_req = MochiReq,
        begin_ts = BeginTime,
        original_method = Method,
        peer = Peer,
        nonce = Nonce
    } = HttpReq,
    #httpd_resp{
        end_ts = EndTime,
        code = Code,
        status = Status
    } = HttpResp,
    Host = MochiReq:get_header_value("Host"),
    RawUri = MochiReq:get(raw_path),
    RequestTime = timer:now_diff(EndTime, BeginTime) / 1000,
    couch_log:notice("~s ~s ~s ~s ~s ~B ~p ~B", [Nonce, Peer, Host,
        Method, RawUri, Code, Status, round(RequestTime)]);
maybe_log(_HttpReq, #httpd_resp{should_log = false}) ->
    ok.


%% HACK: replication currently handles two forms of input, #db{} style
%% and #http_db style. We need a third that makes use of fabric. #db{}
%% works fine for replicating the dbs and nodes database because they
%% aren't sharded. So for now when a local db is specified as the source or
%% the target, it's hacked to make it a full url and treated as a remote.
possibly_hack(#httpd{path_parts=[<<"_replicate">>]}=Req) ->
    {Props0} = couch_httpd:json_body_obj(Req),
    Props1 = fix_uri(Req, Props0, <<"source">>),
    Props2 = fix_uri(Req, Props1, <<"target">>),
    put(post_body, {Props2}),
    Req;
possibly_hack(Req) ->
    Req.

check_request_uri_length(Uri) ->
    check_request_uri_length(Uri, config:get("httpd", "max_uri_length")).

check_request_uri_length(_Uri, undefined) ->
    ok;
check_request_uri_length(Uri, MaxUriLen) when is_list(MaxUriLen) ->
    case length(Uri) > list_to_integer(MaxUriLen) of
        true ->
            throw(request_uri_too_long);
        false ->
            ok
    end.

fix_uri(Req, Props, Type) ->
    case replication_uri(Type, Props) of
    undefined ->
        Props;
    Uri0 ->
        case is_http(Uri0) of
        true ->
            Props;
        false ->
            Uri = make_uri(Req, couch_httpd:quote(Uri0)),
            [{Type,Uri}|proplists:delete(Type,Props)]
        end
    end.

replication_uri(Type, PostProps) ->
    case couch_util:get_value(Type, PostProps) of
    {Props} ->
        couch_util:get_value(<<"url">>, Props);
    Else ->
        Else
    end.

is_http(<<"http://", _/binary>>) ->
    true;
is_http(<<"https://", _/binary>>) ->
    true;
is_http(_) ->
    false.

make_uri(Req, Raw) ->
    Port = integer_to_list(mochiweb_socket_server:get(chttpd, port)),
    Url = list_to_binary(["http://", config:get("httpd", "bind_address"),
                          ":", Port, "/", Raw]),
    Headers = [
        {<<"authorization">>, ?l2b(couch_httpd:header_value(Req,"authorization",""))},
        {<<"cookie">>, ?l2b(extract_cookie(Req))}
    ],
    {[{<<"url">>,Url}, {<<"headers">>,{Headers}}]}.

extract_cookie(#httpd{mochi_req = MochiReq}) ->
    case MochiReq:get_cookie_value("AuthSession") of
        undefined ->
            "";
        AuthSession ->
            "AuthSession=" ++ AuthSession
    end.
%%% end hack

authenticate_request(Req) ->
    AuthenticationFuns = [
        {<<"cookie">>, fun couch_httpd_auth_plugin:cookie_authentication_handler/1},
        {<<"default">>, fun couch_httpd_auth_plugin:default_authentication_handler/1},
        {<<"local">>, fun couch_httpd_auth_plugin:party_mode_handler/1} %% should be last
    ],
    authenticate_request(Req, chttpd_auth_cache, AuthenticationFuns).

authenticate_request(#httpd{} = Req0, AuthModule, AuthFuns) ->
    Req = Req0#httpd{
        auth_module = AuthModule,
        authentication_handlers = AuthFuns},
    authenticate_request(Req, AuthFuns).

% Try authentication handlers in order until one returns a result
authenticate_request(#httpd{user_ctx=#user_ctx{}} = Req, _AuthFuns) ->
    Req;
authenticate_request(#httpd{} = Req, [{Name, AuthFun}|Rest]) ->
    authenticate_request(maybe_set_handler(AuthFun(Req), Name), Rest);
authenticate_request(Response, _AuthFuns) ->
    Response.

maybe_set_handler(#httpd{user_ctx=#user_ctx{} = UserCtx} = Req, Name) ->
    Req#httpd{user_ctx = UserCtx#user_ctx{handler = Name}};
maybe_set_handler(Else, _) ->
    Else.

increment_method_stats(Method) ->
    couch_stats:increment_counter([couchdb, httpd_request_methods, Method]).
