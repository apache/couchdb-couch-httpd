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

-module(couch_httpd_original).
-include_lib("couch/include/couch_db.hrl").

-export([start_link/0, start_link/1, stop/0, handle_request/5]).


-export([verify_is_server_admin/1,error_info/1]).
-export([make_fun_spec_strs/1]).


-export([send_error/2,send_error/4, send_chunked_error/2]).
-export([handle_request_int/5]).


-import(couch_httpd, [
    server_header/0,
    last_chunk/1,
    start_json_response/2,
    start_json_response/3,
    end_json_response/1,
    send_json/2,
    send_json/3,
    send_json/4,
    validate_ctype/2,
    header_value/2,
    header_value/3,
    qs_value/2,
    qs_value/3,
    qs/1,
    qs_json_value/3,
    path/1,
    body_length/1,
    unquote/1,
    quote/1,
    recv/2,
    recv_chunked/4,
    json_body/1,
    json_body_obj/1,
    parse_form/1,
    doc_etag/1,
    make_etag/1,
    primary_header_value/2,
    partition/1,
    serve_file/3,
    serve_file/4,
    send/2,
    send_method_not_allowed/2,
    send_redirect/2,
    absolute_uri/2,
    body/1,
    log_request/2,
    etag_respond/3,
    etag_match/2,
    start_reponse/3,
    start_response_length/4,
    send_chunk/2,
    etag_maybe/2,
    send_response/4,
    start_chunked_response/3,
    validate_host/1,
    accepted_encodings/1,
    validate_referer/1,
    validate_bind_address/1
]).

-define(HANDLER_NAME_IN_MODULE_POS, 6).

start_link() ->
    start_link(http).
start_link(http) ->
    Port = config:get("httpd", "port", "5984"),
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
            couch_log:error("SSL enabled but PEM certificates are missing", []),
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
                    [{verify_fun, couch_httpd_util:fun_from_spec(SpecStr, 3)}]
            end
    end,
    SslOpts = ServerOpts ++ ClientOpts,

    Options =
        [{port, Port},
         {ssl, true},
         {ssl_opts, SslOpts}],
    start_link(https, Options).
start_link(Name, Options) ->
    BindAddress = case config:get("httpd", "bind_address", "any") of
                      "any" -> any;
                      Else -> Else
                  end,
    ok = validate_bind_address(BindAddress),
    DefaultSpec = "{couch_httpd_db, handle_request}",
    DefaultFun = couch_httpd_util:fun_from_spec(
        config:get("httpd", "default_handler", DefaultSpec),
        1
    ),

    UrlHandlersList = lists:map(
        fun({UrlKey, SpecStr}) ->
            {?l2b(UrlKey), couch_httpd_util:fun_from_spec(SpecStr, 1)}
        end, config:get("httpd_global_handlers")),

    DbUrlHandlersList = lists:map(
        fun({UrlKey, SpecStr}) ->
            {?l2b(UrlKey), couch_httpd_util:fun_from_spec(SpecStr, 2)}
        end, config:get("httpd_db_handlers")),

    DesignUrlHandlersList = lists:map(
        fun({UrlKey, SpecStr}) ->
            {?l2b(UrlKey), couch_httpd_util:fun_from_spec(SpecStr, 3)}
        end, config:get("httpd_design_handlers")),

    UrlHandlers = dict:from_list(UrlHandlersList),
    DbUrlHandlers = dict:from_list(DbUrlHandlersList),
    DesignUrlHandlers = dict:from_list(DesignUrlHandlersList),
    {ok, ServerOptions} = couch_util:parse_term(
        config:get("httpd", "server_options", "[]")),
    {ok, SocketOptions} = couch_util:parse_term(
        config:get("httpd", "socket_options", "[]")),

    set_auth_handlers(),

    % ensure uuid is set so that concurrent replications
    % get the same value.
    couch_server:get_uuid(),

    Loop = fun(Req)->
        case SocketOptions of
        [] ->
            ok;
        _ ->
            ok = mochiweb_socket:setopts(Req:get(socket), SocketOptions)
        end,
        apply(?MODULE, handle_request, [
            Req, DefaultFun, UrlHandlers, DbUrlHandlers, DesignUrlHandlers
        ])
    end,

    % set mochiweb options
    FinalOptions = lists:append([Options, ServerOptions, [
            {loop, Loop},
            {name, Name},
            {ip, BindAddress}]]),

    % launch mochiweb
    case mochiweb_http:start(FinalOptions) of
        {ok, MochiPid} ->
            {ok, MochiPid};
        {error, Reason} ->
            couch_log:error("Failure to start Mochiweb: ~s~n", [Reason]),
            throw({error, Reason})
    end.


stop() ->
    mochiweb_http:stop(couch_httpd),
    catch mochiweb_http:stop(https).


set_auth_handlers() ->
    AuthenticationSrcs = make_fun_spec_strs(
        config:get("httpd", "authentication_handlers", "")),
    AuthHandlers = lists:map(
        fun(A) -> {auth_handler_name(A), couch_httpd_util:fun_from_spec(A, 1)} end, AuthenticationSrcs),
    AuthenticationFuns = AuthHandlers ++ [
        {<<"local">>, fun couch_httpd_auth:party_mode_handler/1} %% should be last
    ],
    ok = application:set_env(couch, auth_handlers, AuthenticationFuns).

auth_handler_name(SpecStr) ->
    lists:nth(?HANDLER_NAME_IN_MODULE_POS, re:split(SpecStr, "[\\W_]", [])).


% SpecStr is "{my_module, my_fun}, {my_module2, my_fun2}"
make_fun_spec_strs(SpecStr) ->
    re:split(SpecStr, "(?<=})\\s*,\\s*(?={)", [{return, list}]).

handle_request(MochiReq, DefaultFun, UrlHandlers, DbUrlHandlers,
    DesignUrlHandlers) ->
    %% reset rewrite count for new request
    erlang:put(?REWRITE_COUNT, 0),

    MochiReq1 = couch_httpd_vhost:dispatch_host(MochiReq),

    handle_request_int(MochiReq1, DefaultFun,
                UrlHandlers, DbUrlHandlers, DesignUrlHandlers).

handle_request_int(MochiReq, DefaultFun,
            UrlHandlers, DbUrlHandlers, DesignUrlHandlers) ->
    Begin = os:timestamp(),
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

    HandlerKey =
    case mochiweb_util:partition(Path, "/") of
    {"", "", ""} ->
        <<"/">>; % Special case the root url handler
    {FirstPart, _, _} ->
        list_to_binary(FirstPart)
    end,
    couch_log:debug("~p ~s ~p from ~p~nHeaders: ~p", [
        MochiReq:get(method),
        RawUri,
        MochiReq:get(version),
        MochiReq:get(peer),
        mochiweb_headers:to_list(MochiReq:get(headers))
    ]),

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
    Method2 = case lists:member(MethodOverride, ["GET", "HEAD", "POST",
                                                 "PUT", "DELETE",
                                                 "TRACE", "CONNECT",
                                                 "COPY"]) of
    true ->
        couch_log:info("MethodOverride: ~s (real method was ~s)",
                       [MethodOverride, Method1]),
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

    HttpReq = #httpd{
        mochi_req = MochiReq,
        peer = MochiReq:get(peer),
        method = Method,
        requested_path_parts =
            [?l2b(unquote(Part)) || Part <- string:tokens(RequestedPath, "/")],
        path_parts = [?l2b(unquote(Part)) || Part <- string:tokens(Path, "/")],
        db_url_handlers = DbUrlHandlers,
        design_url_handlers = DesignUrlHandlers,
        default_fun = DefaultFun,
        url_handlers = UrlHandlers,
        user_ctx = erlang:erase(pre_rewrite_user_ctx),
        auth = erlang:erase(pre_rewrite_auth)
    },

    HandlerFun = couch_util:dict_find(HandlerKey, UrlHandlers, DefaultFun),

    {ok, Resp} =
    try
        validate_host(HttpReq),
        check_request_uri_length(RawUri),
        case couch_httpd_cors:is_preflight_request(HttpReq) of
        #httpd{} ->
            case authenticate_request(HttpReq) of
            #httpd{} = Req ->
                HandlerFun(Req);
            Response ->
                Response
            end;
        Response ->
            Response
        end
    catch
        throw:{http_head_abort, Resp0} ->
            {ok, Resp0};
        throw:{invalid_json, S} ->
            couch_log:error("attempted upload of invalid JSON"
                            " (set log_level to debug to log it)", []),
            couch_log:debug("Invalid JSON: ~p",[S]),
            send_error(HttpReq, {bad_request, invalid_json});
        throw:unacceptable_encoding ->
            couch_log:error("unsupported encoding method for the response", []),
            send_error(HttpReq, {not_acceptable, "unsupported encoding"});
        throw:bad_accept_encoding_value ->
            couch_log:error("received invalid Accept-Encoding header", []),
            send_error(HttpReq, bad_request);
        exit:normal ->
            exit(normal);
        exit:snappy_nif_not_loaded ->
            ErrorReason = "To access the database or view index, Apache CouchDB"
                          " must be built with Erlang OTP R13B04 or higher.",
            couch_log:error("~s", [ErrorReason]),
            send_error(HttpReq, {bad_otp_release, ErrorReason});
        exit:{body_too_large, _} ->
            send_error(HttpReq, request_entity_too_large);
        exit:{uri_too_long, _} ->
            send_error(HttpReq, request_uri_too_long);
        throw:Error ->
            Stack = erlang:get_stacktrace(),
            couch_log:debug("Minor error in HTTP request: ~p",[Error]),
            couch_log:debug("Stacktrace: ~p",[Stack]),
            send_error(HttpReq, Error);
        error:badarg ->
            Stack = erlang:get_stacktrace(),
            couch_log:error("Badarg error in HTTP request",[]),
            couch_log:info("Stacktrace: ~p",[Stack]),
            send_error(HttpReq, badarg);
        error:function_clause ->
            Stack = erlang:get_stacktrace(),
            couch_log:error("function_clause error in HTTP request",[]),
            couch_log:info("Stacktrace: ~p",[Stack]),
            send_error(HttpReq, function_clause);
        Tag:Error ->
            Stack = erlang:get_stacktrace(),
            couch_log:error("Uncaught error in HTTP request: ~p",
                            [{Tag, Error}]),
            couch_log:info("Stacktrace: ~p",[Stack]),
            send_error(HttpReq, Error)
    end,
    RequestTime = round(timer:now_diff(os:timestamp(), Begin)/1000),
    couch_stats:update_histogram([couchdb, request_time], RequestTime),
    couch_stats:increment_counter([couchdb, httpd, requests]),
    {ok, Resp}.


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

authenticate_request(Req) ->
    {ok, AuthenticationFuns} = application:get_env(couch, auth_handlers),
    couch_httpd:authenticate_request(Req, couch_auth_cache, AuthenticationFuns).

increment_method_stats(Method) ->
    couch_stats:increment_counter([couchdb, httpd_request_methods, Method]).



% Utilities



verify_is_server_admin(#httpd{user_ctx=UserCtx}) ->
    verify_is_server_admin(UserCtx);
verify_is_server_admin(#user_ctx{roles=Roles}) ->
    case lists:member(<<"_admin">>, Roles) of
    true -> ok;
    false -> throw({unauthorized, <<"You are not a server admin.">>})
    end.

error_info({Error, Reason}) when is_list(Reason) ->
    error_info({Error, ?l2b(Reason)});
error_info(bad_request) ->
    {400, <<"bad_request">>, <<>>};
error_info({bad_request, Reason}) ->
    {400, <<"bad_request">>, Reason};
error_info({query_parse_error, Reason}) ->
    {400, <<"query_parse_error">>, Reason};
% Prior art for md5 mismatch resulting in a 400 is from AWS S3
error_info(md5_mismatch) ->
    {400, <<"content_md5_mismatch">>, <<"Possible message corruption.">>};
error_info({illegal_docid, Reason}) ->
    {400, <<"illegal_docid">>, Reason};
error_info(not_found) ->
    {404, <<"not_found">>, <<"missing">>};
error_info({not_found, Reason}) ->
    {404, <<"not_found">>, Reason};
error_info({not_acceptable, Reason}) ->
    {406, <<"not_acceptable">>, Reason};
error_info(conflict) ->
    {409, <<"conflict">>, <<"Document update conflict.">>};
error_info({forbidden, Msg}) ->
    {403, <<"forbidden">>, Msg};
error_info({unauthorized, Msg}) ->
    {401, <<"unauthorized">>, Msg};
error_info(file_exists) ->
    {412, <<"file_exists">>, <<"The database could not be "
        "created, the file already exists.">>};
error_info(request_entity_too_large) ->
    {413, <<"too_large">>, <<"the request entity is too large">>};
error_info(request_uri_too_long) ->
    {414, <<"too_long">>, <<"the request uri is too long">>};
error_info({bad_ctype, Reason}) ->
    {415, <<"bad_content_type">>, Reason};
error_info(requested_range_not_satisfiable) ->
    {416, <<"requested_range_not_satisfiable">>, <<"Requested range not satisfiable">>};
error_info({error, {illegal_database_name, Name}}) ->
    Message = <<"Name: '", Name/binary, "'. Only lowercase characters (a-z), ",
        "digits (0-9), and any of the characters _, $, (, ), +, -, and / ",
        "are allowed. Must begin with a letter.">>,
    {400, <<"illegal_database_name">>, Message};
error_info({missing_stub, Reason}) ->
    {412, <<"missing_stub">>, Reason};
error_info({Error, Reason}) ->
    {500, couch_util:to_binary(Error), couch_util:to_binary(Reason)};
error_info(Error) ->
    {500, <<"unknown_error">>, couch_util:to_binary(Error)}.

error_headers(#httpd{mochi_req=MochiReq}=Req, Code, ErrorStr, ReasonStr) ->
    if Code == 401 ->
        % this is where the basic auth popup is triggered
        case MochiReq:get_header_value("X-CouchDB-WWW-Authenticate") of
        undefined ->
            case config:get("httpd", "WWW-Authenticate", undefined) of
            undefined ->
                % If the client is a browser and the basic auth popup isn't turned on
                % redirect to the session page.
                case ErrorStr of
                <<"unauthorized">> ->
                    case config:get("couch_httpd_auth", "authentication_redirect", undefined) of
                    undefined -> {Code, []};
                    AuthRedirect ->
                        case config:get("couch_httpd_auth", "require_valid_user", "false") of
                        "true" ->
                            % send the browser popup header no matter what if we are require_valid_user
                            {Code, [{"WWW-Authenticate", "Basic realm=\"server\""}]};
                        _False ->
                            case MochiReq:accepts_content_type("application/json") of
                            true ->
                                {Code, []};
                            false ->
                                case MochiReq:accepts_content_type("text/html") of
                                true ->
                                    % Redirect to the path the user requested, not
                                    % the one that is used internally.
                                    UrlReturnRaw = case MochiReq:get_header_value("x-couchdb-vhost-path") of
                                    undefined ->
                                        MochiReq:get(path);
                                    VHostPath ->
                                        VHostPath
                                    end,
                                    RedirectLocation = lists:flatten([
                                        AuthRedirect,
                                        "?return=", couch_util:url_encode(UrlReturnRaw),
                                        "&reason=", couch_util:url_encode(ReasonStr)
                                    ]),
                                    {302, [{"Location", absolute_uri(Req, RedirectLocation)}]};
                                false ->
                                    {Code, []}
                                end
                            end
                        end
                    end;
                _Else ->
                    {Code, []}
                end;
            Type ->
                {Code, [{"WWW-Authenticate", Type}]}
            end;
        Type ->
           {Code, [{"WWW-Authenticate", Type}]}
        end;
    true ->
        {Code, []}
    end.

send_error(_Req, {already_sent, Resp, _Error}) ->
    {ok, Resp};

send_error(Req, Error) ->
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    {Code1, Headers} = error_headers(Req, Code, ErrorStr, ReasonStr),
    send_error(Req, Code1, Headers, ErrorStr, ReasonStr).

send_error(Req, Code, ErrorStr, ReasonStr) ->
    send_error(Req, Code, [], ErrorStr, ReasonStr).

send_error(Req, Code, Headers, ErrorStr, ReasonStr) ->
    send_json(Req, Code, Headers,
        {[{<<"error">>,  ErrorStr},
         {<<"reason">>, ReasonStr}]}).


send_chunked_error(Resp, Error) ->
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    JsonError = {[{<<"code">>, Code},
        {<<"error">>,  ErrorStr},
        {<<"reason">>, ReasonStr}]},
    send_chunk(Resp, ?l2b([$\n,?JSON_ENCODE(JsonError),$\n])),
    last_chunk(Resp).







%%%%%%%% module tests below %%%%%%%%

-ifdef(TEST).
-include_lib("couch/include/couch_eunit.hrl").

maybe_add_default_headers_test_() ->
    DummyRequest = [],
    NoCache = {"Cache-Control", "no-cache"},
    ApplicationJson = {"Content-Type", "application/json"},
    % couch_httpd uses process dictionary to check if currently in a
    % json serving method. Defaults to 'application/javascript' otherwise.
    % Therefore must-revalidate and application/javascript should be added
    % by chttpd if such headers are not present
    MustRevalidate = {"Cache-Control", "must-revalidate"},
    ApplicationJavascript = {"Content-Type", "application/javascript"},
    Cases = [
        {[],
         [MustRevalidate, ApplicationJavascript],
          "Should add Content-Type and Cache-Control to empty heaeders"},

        {[NoCache],
         [NoCache, ApplicationJavascript],
          "Should add Content-Type only if Cache-Control is present"},

        {[ApplicationJson],
         [MustRevalidate, ApplicationJson],
          "Should add Cache-Control if Content-Type is present"},

        {[NoCache, ApplicationJson],
         [NoCache, ApplicationJson],
          "Should not add headers if Cache-Control and Content-Type are there"}
    ],
    Tests = lists:map(fun({InitialHeaders, ProperResult, Desc}) ->
        {Desc,
        ?_assertEqual(ProperResult,
         maybe_add_default_headers(DummyRequest, InitialHeaders))}
    end, Cases),
    {"Tests adding default headers", Tests}.

-endif.
