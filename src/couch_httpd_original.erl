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


-export([make_fun_spec_strs/1]).


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
    validate_bind_address/1,
    verify_is_server_admin/1,
    error_info/1,
    send_error/2,
    send_error/4,
    send_chunked_error/2
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
