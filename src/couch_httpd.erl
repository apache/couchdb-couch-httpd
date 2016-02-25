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

-module(couch_httpd).
-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_httpd/include/couch_httpd.hrl").

-export([
    start_response_length/4,
    start_chunked_response/3,
    start_json_response/2,
    start_json_response/3,
    end_json_response/1
]).

-export([
    start_delayed_response/1,
    start_delayed_chunked_response/3,
    start_delayed_chunked_response/4,
    start_delayed_json_response/2,
    start_delayed_json_response/3,
    start_delayed_json_response/4
]).

-export([
    send_response/4,
    send_json/2,
    send_json/3,
    send_json/4,
    send_redirect/2,
    send/2
]).

-export([
    send_delayed_chunk/2,
    send_delayed_last_chunk/1,
    end_delayed_json_response/1,
    close_delayed_json_object/4
]).

-export([
    log_request/2,
    server_header/0,
    send_chunk/2,
    last_chunk/1
]).

-export([
    qs_value/2,
    qs_value/3,
    qs_json_value/3,
    qs/1
]).

-export([
    absolute_uri/2,
    partition/1,
    header_value/2,
    header_value/3,
    primary_header_value/2,
    serve_file/3,
    serve_file/4,
    path/1,
    unquote/1,
    quote/1,
    parse_form/1,
    recv/2,
    recv_chunked/4,
    body_length/1,
    body/1,
    json_body/1,
    json_body_obj/1,
    verify_is_server_admin/1,
    get_delayed_req/1,
    chunked_response_buffer_size/0
]).

-export([
    validate_ctype/2
]).

-export([
    doc_etag/1,
    make_etag/1,
    etag_match/2,
    etag_respond/3
]).

-export([
    error_info/1,
    send_error/2,
    send_error/4,
    send_chunked_error/2,
    send_delayed_error/2,
    send_method_not_allowed/2
]).


-record(delayed_resp, {
    start_fun,
    req,
    code,
    headers,
    first_chunk,
    resp=nil
}).

start_response_length(#httpd{mochi_req=MochiReq}=Req, Code, Headers0, Length) ->
    couch_stats:increment_counter([couchdb, httpd_status_codes, Code]),
    Headers1 = Headers0 ++ server_header() ++
	couch_httpd_auth:cookie_auth_header(Req, Headers0),
    Headers2 = couch_httpd_cors:headers(Req, Headers1),
    Resp = MochiReq:start_response_length({Code, Headers2, Length}),
    case MochiReq:get(method) of
    'HEAD' -> throw({http_head_abort, Resp});
    _ -> ok
    end,
    {ok, Resp}.

start_chunked_response(#httpd{mochi_req=MochiReq}=Req, Code, Headers0) ->
    couch_stats:increment_counter([couchdb, httpd_status_codes, Code]),
    Headers1 = Headers0 ++ server_header() ++
        couch_httpd_auth:cookie_auth_header(Req, Headers0),
    Headers2 = couch_httpd_cors:headers(Req, Headers1),
    Resp = MochiReq:respond({Code, Headers2, chunked}),
    case MochiReq:get(method) of
    'HEAD' -> throw({http_head_abort, Resp});
    _ -> ok
    end,
    {ok, Resp}.

start_json_response(Req, Code) ->
    start_json_response(Req, Code, []).

start_json_response(Req, Code, Headers0) ->
    Headers1 = [timing(), reqid() | Headers0],
    initialize_jsonp(Req),
    AllHeaders = maybe_add_default_headers(Req, Headers1),
    {ok, Resp} = start_chunked_response(Req, Code, AllHeaders),
    case start_jsonp() of
        [] -> ok;
        Start -> send_chunk(Resp, Start)
    end,
    {ok, Resp}.

start_delayed_response(#delayed_resp{resp=nil}=DelayedResp) ->
    #delayed_resp{
        start_fun=StartFun,
        req=Req,
        code=Code,
        headers=Headers,
        first_chunk=FirstChunk
    }=DelayedResp,
    {ok, Resp} = StartFun(Req, Code, Headers),
    case FirstChunk of
        "" -> ok;
        _ -> {ok, Resp} = send_chunk(Resp, FirstChunk)
    end,
    {ok, DelayedResp#delayed_resp{resp=Resp}};
start_delayed_response(#delayed_resp{}=DelayedResp) ->
    {ok, DelayedResp}.

start_delayed_chunked_response(Req, Code, Headers) ->
    start_delayed_chunked_response(Req, Code, Headers, "").

start_delayed_chunked_response(Req, Code, Headers, FirstChunk) ->
    {ok, #delayed_resp{
        start_fun = fun start_chunked_response/3,
        req = Req,
        code = Code,
        headers = Headers,
        first_chunk = FirstChunk}}.

start_delayed_json_response(Req, Code) ->
    start_delayed_json_response(Req, Code, []).

start_delayed_json_response(Req, Code, Headers) ->
    start_delayed_json_response(Req, Code, Headers, "").

start_delayed_json_response(Req, Code, Headers, FirstChunk) ->
    {ok, #delayed_resp{
        start_fun = fun start_json_response/3,
        req = Req,
        code = Code,
        headers = Headers,
        first_chunk = FirstChunk}}.

send_response(#httpd{mochi_req=MochiReq}=Req, Code, Headers0, Body) ->
    couch_stats:increment_counter([couchdb, httpd_status_codes, Code]),
    Headers = Headers0 ++ server_header() ++
	[timing(), reqid() | couch_httpd_auth:cookie_auth_header(Req, Headers0)],
    {ok, MochiReq:respond({Code, Headers, Body})}.

send_json(Req, Value) ->
    send_json(Req, 200, Value).

send_json(Req, Code, Value) ->
    send_json(Req, Code, [], Value).

send_json(Req, Code, Headers0, Value) ->
    Headers1 = [timing(), reqid() | Headers0],
    Headers2 = couch_httpd_cors:headers(Req, Headers1),
    initialize_jsonp(Req),
    AllHeaders = maybe_add_default_headers(Req, Headers2),
    Body = [start_jsonp(), ?JSON_ENCODE(Value), end_jsonp(), $\n],
    send_response(Req, Code, AllHeaders, Body).

send_redirect(Req, Path) ->
    Headers0 = [{"Location", absolute_uri(Req, Path)}],
    Headers1 = couch_httpd_cors:headers(Req, Headers0),
    send_response(Req, 301, Headers1, <<>>).

send_delayed_chunk(#delayed_resp{}=DelayedResp, Chunk) ->
    {ok, #delayed_resp{resp=Resp}=DelayedResp1} =
        start_delayed_response(DelayedResp),
    {ok, Resp} = send_chunk(Resp, Chunk),
    {ok, DelayedResp1}.

send_delayed_last_chunk(Req) ->
    send_delayed_chunk(Req, []).

end_delayed_json_response(#delayed_resp{}=DelayedResp) ->
    {ok, #delayed_resp{resp=Resp}} =
        start_delayed_response(DelayedResp),
    end_json_response(Resp).

close_delayed_json_object(Resp, Buffer, Terminator, 0) ->
    % Use a separate chunk to close the streamed array to maintain strict
    % compatibility with earlier versions. See COUCHDB-2724
    {ok, R1} = send_delayed_chunk(Resp, Buffer),
    send_delayed_chunk(R1, Terminator);
close_delayed_json_object(Resp, Buffer, Terminator, _Threshold) ->
    send_delayed_chunk(Resp, [Buffer | Terminator]).

end_json_response(Resp) ->
    send_chunk(Resp, end_jsonp() ++ [$\n]),
    last_chunk(Resp).

send_error(_Req, {already_sent, Resp, _Error}) ->
    {ok, Resp};

send_error(Req, Error) ->
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    {Code1, Headers} = error_headers(Req, Code, ErrorStr, ReasonStr),
    send_error(Req, Code1, Headers, ErrorStr, ReasonStr, json_stack(Error)).

send_error(Req, Code, ErrorStr, ReasonStr) ->
    send_error(Req, Code, [], ErrorStr, ReasonStr, []).

send_error(Req, Code, Headers, ErrorStr, ReasonStr, []) ->
    send_json(Req, Code, Headers,
        {[{<<"error">>,  ErrorStr},
        {<<"reason">>, ReasonStr}]});
send_error(Req, Code, Headers, ErrorStr, ReasonStr, Stack) ->
    log_error_with_stack_trace({ErrorStr, ReasonStr, Stack}),
    send_json(Req, Code, [stack_trace_id(Stack) | Headers],
        {[{<<"error">>,  ErrorStr},
        {<<"reason">>, ReasonStr} |
        case Stack of [] -> []; _ -> [{<<"ref">>, stack_hash(Stack)}] end
    ]}).

% give the option for list functions to output html or other raw errors
send_chunked_error(Resp, {_Error, {[{<<"body">>, Reason}]}}) ->
    send_chunk(Resp, Reason),
    send_chunk(Resp, []);

send_chunked_error(Resp, Error) ->
    Stack = json_stack(Error),
    log_error_with_stack_trace(Error),
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    JsonError = {[{<<"code">>, Code},
        {<<"error">>,  ErrorStr},
        {<<"reason">>, ReasonStr} |
        case Stack of [] -> []; _ -> [{<<"ref">>, stack_hash(Stack)}] end
    ]},
    send_chunk(Resp, ?l2b([$\n,?JSON_ENCODE(JsonError),$\n])),
    send_chunk(Resp, []).

send_delayed_error(#delayed_resp{req=Req,resp=nil}=DelayedResp, Reason) ->
    {Code, ErrorStr, ReasonStr} = error_info(Reason),
    {ok, Resp} = send_error(Req, Code, ErrorStr, ReasonStr),
    {ok, DelayedResp#delayed_resp{resp=Resp}};
send_delayed_error(#delayed_resp{resp=Resp}, Reason) ->
    log_error_with_stack_trace(Reason),
    throw({http_abort, Resp, Reason}).

%% =========
%% Utilities

partition(Path) ->
    mochiweb_util:partition(Path, "/").

header_value(#httpd{mochi_req=MochiReq}, Key) ->
    MochiReq:get_header_value(Key).

header_value(#httpd{mochi_req=MochiReq}, Key, Default) ->
    case MochiReq:get_header_value(Key) of
    undefined -> Default;
    Value -> Value
    end.

primary_header_value(#httpd{mochi_req=MochiReq}, Key) ->
    MochiReq:get_primary_header_value(Key).

serve_file(Req, RelativePath, DocumentRoot) ->
    serve_file(Req, RelativePath, DocumentRoot, []).

serve_file(#httpd{mochi_req=MochiReq}=Req, RelativePath, DocumentRoot,
           ExtraHeaders) ->
    Headers = server_header() ++
	couch_httpd_auth:cookie_auth_header(Req, []) ++
	ExtraHeaders,
    Headers1 = couch_httpd_cors:headers(Req, Headers),
    {ok, MochiReq:serve_file(RelativePath, DocumentRoot, Headers1)}.

path(#httpd{mochi_req=MochiReq}) ->
    MochiReq:get(path).

unquote(UrlEncodedString) ->
    mochiweb_util:unquote(UrlEncodedString).

quote(UrlDecodedString) ->
    mochiweb_util:quote_plus(UrlDecodedString).

parse_form(#httpd{mochi_req=MochiReq}) ->
    mochiweb_multipart:parse_form(MochiReq).

recv(#httpd{mochi_req=MochiReq}, Len) ->
    MochiReq:recv(Len).

recv_chunked(#httpd{mochi_req=MochiReq}, MaxChunkSize, ChunkFun, InitState) ->
    % Fun is called once with each chunk
    % Fun({Length, Binary}, State)
    % called with Length == 0 on the last time.
    MochiReq:stream_body(MaxChunkSize, ChunkFun, InitState).

body_length(#httpd{mochi_req=MochiReq}) ->
    MochiReq:get(body_length).

body(#httpd{mochi_req=MochiReq, req_body=undefined}) ->
    % Maximum size of document PUT request body (4GB)
    MaxSize = list_to_integer(
        config:get("couchdb", "max_document_size", "4294967296")),
    Begin = os:timestamp(),
    try
        MochiReq:recv_body(MaxSize)
    after
        T = timer:now_diff(os:timestamp(), Begin) div 1000,
        put(body_time, T)
    end;
body(#httpd{req_body=ReqBody}) ->
    ReqBody.


json_body(Httpd) ->
    case body(Httpd) of
        undefined ->
            throw({bad_request, "Missing request body"});
        Body ->
            ?JSON_DECODE(maybe_decompress(Httpd, Body))
    end.

json_body_obj(Httpd) ->
    case json_body(Httpd) of
        {Props} -> {Props};
        _Else ->
            throw({bad_request, "Request body must be a JSON object"})
    end.

validate_ctype(Req, Ctype) ->
    case header_value(Req, "Content-Type") of
    undefined ->
        throw({bad_ctype, "Content-Type must be "++Ctype});
    ReqCtype ->
        case string:tokens(ReqCtype, ";") of
        [Ctype] -> ok;
        [Ctype | _Rest] -> ok;
        _Else ->
            throw({bad_ctype, "Content-Type must be "++Ctype})
        end
    end.

host_for_request(#httpd{mochi_req = MochiReq}) ->
    XHost = config:get("httpd", "x_forwarded_host", "X-Forwarded-Host"),
    case MochiReq:get_header_value(XHost) of
        undefined ->
            case MochiReq:get_header_value("Host") of
                undefined ->
                    {ok, {Address, Port}} = case MochiReq:get(socket) of
                        {ssl, SslSocket} -> ssl:sockname(SslSocket);
                        Socket -> inet:sockname(Socket)
                    end,
                    inet_parse:ntoa(Address) ++ ":" ++ integer_to_list(Port);
                Value1 ->
                    Value1
            end;
        Value -> Value
    end.

absolute_uri(#httpd{mochi_req=MochiReq, absolute_uri = undefined} = Req, Path) ->
    Host = host_for_request(Req),
    XSsl = config:get("httpd", "x_forwarded_ssl", "X-Forwarded-Ssl"),
    Scheme = case MochiReq:get_header_value(XSsl) of
        "on" -> "https";
        _ ->
            XProto = config:get("httpd", "x_forwarded_proto",
                "X-Forwarded-Proto"),
            case MochiReq:get_header_value(XProto) of
                % Restrict to "https" and "http" schemes only
                "https" -> "https";
                _ ->
                    case MochiReq:get(scheme) of
                        https ->
                            "https";
                        http ->
                            "http"
                    end
            end
    end,
    Scheme ++ "://" ++ Host ++ Path;
absolute_uri(#httpd{absolute_uri = URI}, Path) ->
    URI ++ Path.

doc_etag(#doc{revs={Start, [DiskRev|_]}}) ->
    "\"" ++ ?b2l(couch_doc:rev_to_str({Start, DiskRev})) ++ "\"".

make_etag(Term) ->
    <<SigInt:128/integer>> = couch_crypto:hash(md5, term_to_binary(Term)),
    list_to_binary(io_lib:format("\"~.36B\"",[SigInt])).

etag_match(Req, CurrentEtag) when is_binary(CurrentEtag) ->
    etag_match(Req, binary_to_list(CurrentEtag));

etag_match(Req, CurrentEtag) ->
    EtagsToMatch = string:tokens(
        header_value(Req, "If-None-Match", ""), ", "),
    lists:member(CurrentEtag, EtagsToMatch).

etag_respond(Req, CurrentEtag, RespFun) ->
    case etag_match(Req, CurrentEtag) of
    true ->
        % the client has this in their cache.
        Headers0 = [{"Etag", CurrentEtag}],
        Headers1 = couch_httpd_cors:headers(Req, Headers0),
        send_response(Req, 304, Headers1, <<>>);
    false ->
        % Run the function.
        RespFun()
    end.

verify_is_server_admin(#httpd{user_ctx=#user_ctx{roles=Roles}}) ->
    case lists:member(<<"_admin">>, Roles) of
    true -> ok;
    false -> throw({unauthorized, <<"You are not a server admin.">>})
    end.


send_method_not_allowed(Req, Methods) ->
    send_error(Req, 405, [{"Allow", Methods}], <<"method_not_allowed">>,
        ?l2b("Only " ++ Methods ++ " allowed"), []).

get_delayed_req(#delayed_resp{req=#httpd{mochi_req=MochiReq}}) ->
    MochiReq;
get_delayed_req(Resp) ->
    Resp:get(request).

%% @doc CouchDB uses a chunked transfer-encoding to stream responses to
%% _all_docs, _changes, _view and other similar requests. This configuration
%% value sets the maximum size of a chunk; the system will buffer rows in the
%% response until it reaches this threshold and then send all the rows in one
%% chunk to improve network efficiency. The default value is chosen so that
%% the assembled chunk fits into the default Ethernet frame size (some reserved
%% padding is necessary to accommodate the reporting of the chunk length). Set
%% this value to 0 to restore the older behavior of sending each row in a
%% dedicated chunk.
chunked_response_buffer_size() ->
    config:get_integer("httpd", "chunked_response_buffer", 1490).

%% ================
%% Helper functions

log_request(#httpd{mochi_req=MochiReq,peer=Peer}=Req, Code) ->
    case erlang:get(dont_log_request) of
        true ->
            ok;
        _ ->
            couch_log:notice("~s - - ~s ~s ~B", [
                Peer,
                MochiReq:get(method),
                MochiReq:get(raw_path),
                Code
            ]),
            gen_event:notify(couch_plugin, {log_request, Req, Code})
    end.

server_header() ->
    [{"Server", "CouchDB/" ++ couch_server:get_version() ++
                " (Erlang OTP/" ++ erlang:system_info(otp_release) ++ ")"}].


send(Resp, Data) ->
    Resp:send(Data),
    {ok, Resp}.


send_chunk(Resp, Data) ->
    Resp:write_chunk(Data),
    {ok, Resp}.

last_chunk(Resp) ->
    Resp:write_chunk([]),
    {ok, Resp}.

qs_value(Req, Key) ->
    qs_value(Req, Key, undefined).

qs_value(Req, Key, Default) ->
    couch_util:get_value(Key, qs(Req), Default).

qs_json_value(Req, Key, Default) ->
    case qs_value(Req, Key, Default) of
        Default ->
            Default;
        Result ->
            ?JSON_DECODE(Result)
    end.

qs(#httpd{mochi_req = MochiReq, qs = undefined}) ->
    MochiReq:parse_qs();
qs(#httpd{qs = QS}) ->
    QS.

%% ===============
%% Errors Handling

error_info({Error, Reason}) when is_list(Reason) ->
    error_info({Error, couch_util:to_binary(Reason)});
error_info(bad_request) ->
    {400, <<"bad_request">>, <<>>};
error_info({bad_request, Reason}) ->
    {400, <<"bad_request">>, Reason};
error_info({bad_request, Error, Reason}) ->
    {400, couch_util:to_binary(Error), couch_util:to_binary(Reason)};
error_info({query_parse_error, Reason}) ->
    {400, <<"query_parse_error">>, Reason};
error_info(database_does_not_exist) ->
    {404, <<"not_found">>, <<"Database does not exist.">>};
error_info(not_found) ->
    {404, <<"not_found">>, <<"missing">>};
error_info({not_found, Reason}) ->
    {404, <<"not_found">>, Reason};
error_info({not_acceptable, Reason}) ->
    {406, <<"not_acceptable">>, Reason};
error_info(conflict) ->
    {409, <<"conflict">>, <<"Document update conflict.">>};
error_info({conflict, _}) ->
    {409, <<"conflict">>, <<"Document update conflict.">>};
error_info({forbidden, Error, Msg}) ->
    {403, Error, Msg};
error_info({forbidden, Msg}) ->
    {403, <<"forbidden">>, Msg};
error_info({unauthorized, Msg}) ->
    {401, <<"unauthorized">>, Msg};
error_info(file_exists) ->
    {412, <<"file_exists">>, <<"The database could not be "
        "created, the file already exists.">>};
error_info({error, {nodedown, Reason}}) ->
    {412, <<"nodedown">>, Reason};
error_info({maintenance_mode, Node}) ->
    {412, <<"nodedown">>, Node};
error_info({maintenance_mode, nil, Node}) ->
    {412, <<"nodedown">>, Node};
error_info({w_quorum_not_met, Reason}) ->
    {500, <<"write_quorum_not_met">>, Reason};
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
error_info({illegal_docid, Reason}) ->
    {400, <<"illegal_docid">>, Reason};
error_info({_DocID,{illegal_docid,DocID}}) ->
    {400, <<"illegal_docid">>,DocID};
error_info({error, {database_name_too_long, DbName}}) ->
    {400, <<"database_name_too_long">>,
        <<"At least one path segment of `", DbName/binary, "` is too long.">>};
error_info({missing_stub, Reason}) ->
    {412, <<"missing_stub">>, Reason};
error_info(request_entity_too_large) ->
    {413, <<"too_large">>, <<"the request entity is too large">>};
error_info({error, security_migration_updates_disabled}) ->
    {503, <<"security_migration">>, <<"Updates to security docs are disabled during "
        "security migration.">>};
error_info(not_implemented) ->
    {501, <<"not_implemented">>, <<"this feature is not yet implemented">>};
error_info(timeout) ->
    {500, <<"timeout">>, <<"The request could not be processed in a reasonable"
        " amount of time.">>};
error_info({timeout, _Reason}) ->
    error_info(timeout);
error_info({Error, null}) ->
    error_info(Error);
error_info({_Error, _Reason} = Error) ->
    maybe_handle_error(Error);
error_info({Error, nil, _Stack}) ->
    error_info(Error);
error_info({Error, Reason, _Stack}) ->
    {500, couch_util:to_binary(Error), couch_util:to_binary(Reason)};
error_info(Error) ->
    maybe_handle_error({<<"unknown_error">>, Error}).

maybe_handle_error(Error) ->
    case couch_httpd_plugin:handle_error(Error) of
        {_Code, _Reason, _Description} = Result ->
            Result;
        {Err, Reason} ->
            {500, couch_util:to_binary(Err), couch_util:to_binary(Reason)};
        Error ->
            {500, couch_util:to_binary(Error), null}
    end.


error_headers(#httpd{mochi_req=MochiReq}=Req, 401=Code, ErrorStr, ReasonStr) ->
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
error_headers(_, Code, _, _) ->
    {Code, []}.

%% =================
%% Private functions


timing() ->
    case get(body_time) of
        undefined ->
            {"X-CouchDB-Body-Time", "0"};
        Time ->
            {"X-CouchDB-Body-Time", integer_to_list(Time)}
    end.

reqid() ->
    {"X-Couch-Request-ID", get(nonce)}.

json_stack({bad_request, _, _}) ->
    [];
json_stack({_Error, _Reason, Stack}) when is_list(Stack) ->
    lists:map(fun json_stack_item/1, Stack);
json_stack(_) ->
    [].

json_stack_item({M,F,A}) ->
    list_to_binary(io_lib:format("~s:~s/~B", [M, F, json_stack_arity(A)]));
json_stack_item({M,F,A,L}) ->
    case proplists:get_value(line, L) of
    undefined -> json_stack_item({M,F,A});
    Line -> list_to_binary(io_lib:format("~s:~s/~B L~B",
        [M, F, json_stack_arity(A), Line]))
    end;
json_stack_item(_) ->
    <<"bad entry in stacktrace">>.

json_stack_arity(A) ->
    if is_integer(A) -> A; is_list(A) -> length(A); true -> 0 end.

maybe_decompress(Httpd, Body) ->
    case header_value(Httpd, "Content-Encoding", "identity") of
    "gzip" ->
        try
            zlib:gunzip(Body)
        catch error:data_error ->
            throw({bad_request, "Request body is not properly gzipped."})
        end;
    "identity" ->
        Body;
    Else ->
        throw({bad_ctype, [Else, " is not a supported content encoding."]})
    end.

log_error_with_stack_trace({bad_request, _, _}) ->
    ok;
log_error_with_stack_trace({Error, Reason, Stack}) ->
    EFmt = if is_binary(Error) -> "~s"; true -> "~w" end,
    RFmt = if is_binary(Reason) -> "~s"; true -> "~w" end,
    Fmt = "req_err(~w) " ++ EFmt ++ " : " ++ RFmt ++ "~n    ~p",
    couch_log:error(Fmt, [stack_hash(Stack), Error, Reason, Stack]);
log_error_with_stack_trace(_) ->
    ok.

stack_trace_id(Stack) ->
    {"X-Couch-Stack-Hash", stack_hash(Stack)}.

stack_hash(Stack) ->
    erlang:crc32(term_to_binary(Stack)).

initialize_jsonp(Req) ->
    case get(jsonp) of
        undefined -> put(jsonp, qs_value(Req, "callback", no_jsonp));
        _ -> ok
    end,
    case get(jsonp) of
        no_jsonp -> [];
        [] -> [];
        CallBack ->
            try
                % make sure jsonp is configured on (default off)
                case config:get("httpd", "allow_jsonp", "false") of
                "true" ->
                    validate_callback(CallBack);
                _Else ->
                    put(jsonp, no_jsonp)
                end
            catch
                Error ->
                    put(jsonp, no_jsonp),
                    throw(Error)
            end
    end.

start_jsonp() ->
    case get(jsonp) of
        no_jsonp -> [];
        [] -> [];
        CallBack -> ["/* CouchDB */", CallBack, "("]
    end.

end_jsonp() ->
    case erlang:erase(jsonp) of
        no_jsonp -> [];
        [] -> [];
        _ -> ");"
    end.

negotiate_content_type(_Req) ->
    case get(jsonp) of
        no_jsonp -> "application/json";
        [] -> "application/json";
        _Callback -> "application/javascript"
    end.

maybe_add_default_headers(ForRequest, ToHeaders) ->
    DefaultHeaders = [
        {"Cache-Control", "must-revalidate"},
        {"Content-Type", negotiate_content_type(ForRequest)}
    ],
    lists:ukeymerge(1, lists:keysort(1, ToHeaders), DefaultHeaders).


validate_callback(CallBack) when is_binary(CallBack) ->
    validate_callback(binary_to_list(CallBack));
validate_callback([]) ->
    ok;
validate_callback([Char | Rest]) ->
    case Char of
        _ when Char >= $a andalso Char =< $z -> ok;
        _ when Char >= $A andalso Char =< $Z -> ok;
        _ when Char >= $0 andalso Char =< $9 -> ok;
        _ when Char == $. -> ok;
        _ when Char == $_ -> ok;
        _ when Char == $[ -> ok;
        _ when Char == $] -> ok;
        _ ->
            throw({bad_request, invalid_callback})
    end,
    validate_callback(Rest).
