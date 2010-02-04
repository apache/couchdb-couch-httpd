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

-module(couch_httpd_show).

-export([handle_doc_show_req/3, handle_doc_update_req/3, handle_view_list_req/3,
        handle_doc_show/5, handle_view_list/6, get_fun_key/3]).

-include("couch_db.hrl").

-import(couch_httpd,
    [send_json/2,send_json/3,send_json/4,send_method_not_allowed/2,
    start_json_response/2,send_chunk/2,last_chunk/1,send_chunked_error/2,
    start_chunked_response/3, send_error/4]).
    


% /db/_design/foo/show/bar/docid
% show converts a json doc to a response of any content-type. 
% it looks up the doc an then passes it to the query server.
% then it sends the response from the query server to the http client.


handle_doc_show_req(#httpd{
        path_parts=[_, _, _, _, ShowName, DocId]
    }=Req, Db, DDoc) ->
    % open the doc
    Doc = couch_httpd_db:couch_doc_open(Db, DocId, nil, [conflicts]),
    % we don't handle revs here b/c they are an internal api
    % returns 404 if there is no doc with DocId
    handle_doc_show(Req, Db, DDoc, ShowName, Doc);

handle_doc_show_req(#httpd{
        path_parts=[_, _, _, _, ShowName, DocId|Rest]
    }=Req, Db, DDoc) ->
    
    DocParts = [DocId|Rest],
    DocId1 = string:join([?b2l(P)|| P <- DocParts], "/"),
        
    % open the doc
    Doc = couch_httpd_db:couch_doc_open(Db, ?l2b(DocId1), nil, [conflicts]),
    % we don't handle revs here b/c they are an internal api
    % returns 404 if there is no doc with DocId
    handle_doc_show(Req, Db, DDoc, ShowName, Doc);


handle_doc_show_req(#httpd{
        path_parts=[_, _, _, _, ShowName]
    }=Req, Db, DDoc) ->
    % with no docid the doc is nil
    handle_doc_show(Req, Db, DDoc, ShowName, nil);

handle_doc_show_req(Req, _Db, _DDoc) ->
    send_error(Req, 404, <<"show_error">>, <<"Invalid path.">>).

handle_doc_show(Req, Db, DDoc, ShowName, Doc) ->
    % get responder for ddoc/showname
    CurrentEtag = show_etag(Req, Doc, DDoc, []),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        JsonReq = couch_httpd_external:json_req_obj(Req, Db),
        JsonDoc = couch_query_servers:json_doc(Doc),
        [<<"resp">>, ExternalResp] = 
            couch_query_servers:ddoc_prompt(DDoc, [<<"shows">>, ShowName], [JsonDoc, JsonReq]),
        JsonResp = apply_etag(ExternalResp, CurrentEtag),
        couch_httpd_external:send_external_response(Req, JsonResp)
    end).



show_etag(#httpd{user_ctx=UserCtx}=Req, Doc, DDoc, More) ->
    Accept = couch_httpd:header_value(Req, "Accept"),
    DocPart = case Doc of
        nil -> nil;
        Doc -> couch_httpd:doc_etag(Doc)
    end,
    couch_httpd:make_etag({couch_httpd:doc_etag(DDoc), DocPart, Accept, UserCtx#user_ctx.roles, More}).

get_fun_key(DDoc, Type, Name) ->
    #doc{body={Props}} = DDoc,
    Lang = proplists:get_value(<<"language">>, Props, <<"javascript">>),
    Src = couch_util:get_nested_json_value({Props}, [Type, Name]),
    {Lang, Src}.

% /db/_design/foo/update/bar/docid
% updates a doc based on a request
% handle_doc_update_req(#httpd{method = 'GET'}=Req, _Db, _DDoc) ->
%     % anything but GET
%     send_method_not_allowed(Req, "POST,PUT,DELETE,ETC");
    
handle_doc_update_req(#httpd{
        path_parts=[_, _, _, _, UpdateName, DocId]
    }=Req, Db, DDoc) ->
    Doc = try couch_httpd_db:couch_doc_open(Db, DocId, nil, [conflicts])
    catch
      _ -> nil
    end,
    send_doc_update_response(Req, Db, DDoc, UpdateName, Doc, DocId);

handle_doc_update_req(#httpd{
        path_parts=[_, _, _, _, UpdateName]
    }=Req, Db, DDoc) ->
    send_doc_update_response(Req, Db, DDoc, UpdateName, nil, null);

handle_doc_update_req(Req, _Db, _DDoc) ->
    send_error(Req, 404, <<"update_error">>, <<"Invalid path.">>).

send_doc_update_response(Req, Db, DDoc, UpdateName, Doc, DocId) ->
    JsonReq = couch_httpd_external:json_req_obj(Req, Db, DocId),
    JsonDoc = couch_query_servers:json_doc(Doc),
    case couch_query_servers:ddoc_prompt(DDoc, [<<"updates">>, UpdateName], [JsonDoc, JsonReq]) of
        [<<"up">>, {NewJsonDoc}, JsonResp] ->
            Options = case couch_httpd:header_value(Req, "X-Couch-Full-Commit", "false") of
            "true" ->
                [full_commit];
            _ ->
                []
            end,
            NewDoc = couch_doc:from_json_obj({NewJsonDoc}),
            Code = 201,
            {ok, _NewRev} = couch_db:update_doc(Db, NewDoc, Options);
        [<<"up">>, _Other, JsonResp] ->
            Code = 200,
            ok
    end,
    JsonResp2 = json_apply_field({<<"code">>, Code}, JsonResp),
    % todo set location field
    couch_httpd_external:send_external_response(Req, JsonResp2).


% view-list request with view and list from same design doc.
handle_view_list_req(#httpd{method='GET',
        path_parts=[_, _, DesignName, _, ListName, ViewName]}=Req, Db, DDoc) ->
    handle_view_list(Req, Db, DDoc, ListName, {DesignName, ViewName}, nil);

% view-list request with view and list from different design docs.
handle_view_list_req(#httpd{method='GET',
        path_parts=[_, _, _, _, ListName, ViewDesignName, ViewName]}=Req, Db, DDoc) ->
    handle_view_list(Req, Db, DDoc, ListName, {ViewDesignName, ViewName}, nil);

handle_view_list_req(#httpd{method='GET'}=Req, _Db, _DDoc) ->
    send_error(Req, 404, <<"list_error">>, <<"Invalid path.">>);

handle_view_list_req(#httpd{method='POST',
        path_parts=[_, _, DesignName, _, ListName, ViewName]}=Req, Db, DDoc) ->
    % {Props2} = couch_httpd:json_body(Req),
    ReqBody = couch_httpd:body(Req),
    {Props2} = ?JSON_DECODE(ReqBody),
    Keys = proplists:get_value(<<"keys">>, Props2, nil),
    handle_view_list(Req#httpd{req_body=ReqBody}, Db, DDoc, ListName, {DesignName, ViewName}, Keys);

handle_view_list_req(#httpd{method='POST',
        path_parts=[_, _, _, _, ListName, ViewDesignName, ViewName]}=Req, Db, DDoc) ->
    % {Props2} = couch_httpd:json_body(Req),
    ReqBody = couch_httpd:body(Req),
    {Props2} = ?JSON_DECODE(ReqBody),
    Keys = proplists:get_value(<<"keys">>, Props2, nil),
    handle_view_list(Req#httpd{req_body=ReqBody}, Db, DDoc, ListName, {ViewDesignName, ViewName}, Keys);

handle_view_list_req(#httpd{method='POST'}=Req, _Db, _DDoc) ->
    send_error(Req, 404, <<"list_error">>, <<"Invalid path.">>);

handle_view_list_req(Req, _Db, _DDoc) ->
    send_method_not_allowed(Req, "GET,POST,HEAD").

handle_view_list(Req, Db, DDoc, LName, {ViewDesignName, ViewName}, Keys) ->
    ViewDesignId = <<"_design/", ViewDesignName/binary>>,
    {ViewType, View, Group, QueryArgs} = couch_httpd_view:load_view(Req, Db, {ViewDesignId, ViewName}, Keys),
    Etag = list_etag(Req, Db, Group, {couch_httpd:doc_etag(DDoc), Keys}),    
    couch_httpd:etag_respond(Req, Etag, fun() ->
            output_list(ViewType, Req, Db, DDoc, LName, View, QueryArgs, Etag, Keys)
        end).    

list_etag(#httpd{user_ctx=UserCtx}=Req, Db, Group, More) ->
    Accept = couch_httpd:header_value(Req, "Accept"),
    couch_httpd_view:view_group_etag(Group, Db, {More, Accept, UserCtx#user_ctx.roles}).

output_list(map, Req, Db, DDoc, LName, View, QueryArgs, Etag, Keys) ->
    output_map_list(Req, Db, DDoc, LName, View, QueryArgs, Etag, Keys);
output_list(reduce, Req, Db, DDoc, LName, View, QueryArgs, Etag, Keys) ->
    output_reduce_list(Req, Db, DDoc, LName, View, QueryArgs, Etag, Keys).
    
% next step:
% use with_ddoc_proc/2 to make this simpler
output_map_list(Req, Db, DDoc, LName, View, QueryArgs, Etag, Keys) ->
    #view_query_args{
        limit = Limit,
        skip = SkipCount
    } = QueryArgs,

    FoldAccInit = {Limit, SkipCount, undefined, []},
    {ok, RowCount} = couch_view:get_row_count(View),
    

    couch_query_servers:with_ddoc_proc(DDoc, fun(QServer) ->

        ListFoldHelpers = #view_fold_helper_funs{
            reduce_count = fun couch_view:reduce_to_count/1,
            start_response = StartListRespFun = make_map_start_resp_fun(QServer, Db, LName),
            send_row = make_map_send_row_fun(QServer)
        },        

        {ok, _, FoldResult} = case Keys of
            nil ->
                FoldlFun = couch_httpd_view:make_view_fold_fun(Req, QueryArgs, Etag, Db, RowCount, ListFoldHelpers),        
                    couch_view:fold(View, FoldlFun, FoldAccInit, 
                    couch_httpd_view:make_key_options(QueryArgs));
            Keys ->
                lists:foldl(
                    fun(Key, {ok, _, FoldAcc}) ->
                        QueryArgs2 = QueryArgs#view_query_args{
                                start_key = Key,
                                end_key = Key
                            },
                        FoldlFun = couch_httpd_view:make_view_fold_fun(Req, QueryArgs2, Etag, Db, RowCount, ListFoldHelpers),
                        couch_view:fold(View, FoldlFun, FoldAcc,
                            couch_httpd_view:make_key_options(QueryArgs2))
                    end, {ok, nil, FoldAccInit}, Keys)
            end,
        finish_list(Req, QServer, Etag, FoldResult, StartListRespFun, RowCount)
    end).


output_reduce_list(Req, Db, DDoc, LName, View, QueryArgs, Etag, Keys) ->
    #view_query_args{
        limit = Limit,
        skip = SkipCount,
        group_level = GroupLevel
    } = QueryArgs,

    couch_query_servers:with_ddoc_proc(DDoc, fun(QServer) ->
        StartListRespFun = make_reduce_start_resp_fun(QServer, Db, LName),
        SendListRowFun = make_reduce_send_row_fun(QServer, Db),
        {ok, GroupRowsFun, RespFun} = couch_httpd_view:make_reduce_fold_funs(Req,
            GroupLevel, QueryArgs, Etag,
            #reduce_fold_helper_funs{
                start_response = StartListRespFun,
                send_row = SendListRowFun
            }),
        FoldAccInit = {Limit, SkipCount, undefined, []},
        {ok, FoldResult} = case Keys of
            nil ->
                couch_view:fold_reduce(View, RespFun, FoldAccInit, [{key_group_fun, GroupRowsFun} | 
                    couch_httpd_view:make_key_options(QueryArgs)]);
            Keys ->
                lists:foldl(
                    fun(Key, {ok, FoldAcc}) ->
                        couch_view:fold_reduce(View, RespFun, FoldAcc,
                            [{key_group_fun, GroupRowsFun} | 
                                couch_httpd_view:make_key_options(
                                QueryArgs#view_query_args{start_key=Key, end_key=Key})]
                            )    
                    end, {ok, FoldAccInit}, Keys)
            end,
        finish_list(Req, QServer, Etag, FoldResult, StartListRespFun, null)
    end).


make_map_start_resp_fun(QueryServer, Db, LName) ->
    fun(Req, Etag, TotalRows, Offset, _Acc) ->
        Head = {[{<<"total_rows">>, TotalRows}, {<<"offset">>, Offset}]},
        start_list_resp(QueryServer, LName, Req, Db, Head, Etag)
    end.

make_reduce_start_resp_fun(QueryServer, Db, LName) ->
    fun(Req2, Etag, _Acc) ->
        start_list_resp(QueryServer, LName, Req2, Db, {[]}, Etag)
    end.

start_list_resp(QServer, LName, Req, Db, Head, Etag) ->
    JsonReq = couch_httpd_external:json_req_obj(Req, Db),
    [<<"start">>,Chunks,JsonResp] = couch_query_servers:ddoc_proc_prompt(QServer, 
        [<<"lists">>, LName], [Head, JsonReq]),
    JsonResp2 = apply_etag(JsonResp, Etag),
    #extern_resp_args{
        code = Code,
        ctype = CType,
        headers = ExtHeaders
    } = couch_httpd_external:parse_external_response(JsonResp2),
    JsonHeaders = couch_httpd_external:default_or_content_type(CType, ExtHeaders),
    {ok, Resp} = start_chunked_response(Req, Code, JsonHeaders),
    {ok, Resp, ?b2l(?l2b(Chunks))}.

make_map_send_row_fun(QueryServer) ->
    fun(Resp, Db, Row, IncludeDocs, RowFront) ->
        send_list_row(Resp, QueryServer, Db, Row, RowFront, IncludeDocs)
    end.

make_reduce_send_row_fun(QueryServer, Db) ->
    fun(Resp, Row, RowFront) ->
        send_list_row(Resp, QueryServer, Db, Row, RowFront, false)
    end.

send_list_row(Resp, QueryServer, Db, Row, RowFront, IncludeDoc) ->
    try
        [Go,Chunks] = prompt_list_row(QueryServer, Db, Row, IncludeDoc),
        Chunk = RowFront ++ ?b2l(?l2b(Chunks)),
        send_non_empty_chunk(Resp, Chunk),
        case Go of
            <<"chunks">> ->
                {ok, ""};
            <<"end">> ->
                {stop, stop}
        end
    catch
        throw:Error ->
            send_chunked_error(Resp, Error),
            throw({already_sent, Resp, Error})
    end.


prompt_list_row({Proc, _DDocId}, Db, {{Key, DocId}, Value}, IncludeDoc) ->
    JsonRow = couch_httpd_view:view_row_obj(Db, {{Key, DocId}, Value}, IncludeDoc),
    couch_query_servers:proc_prompt(Proc, [<<"list_row">>, JsonRow]);

prompt_list_row({Proc, _DDocId}, _, {Key, Value}, _IncludeDoc) ->
    JsonRow = {[{key, Key}, {value, Value}]},
    couch_query_servers:proc_prompt(Proc, [<<"list_row">>, JsonRow]).

send_non_empty_chunk(Resp, Chunk) ->
    case Chunk of
        [] -> ok;
        _ -> send_chunk(Resp, Chunk)
    end.

finish_list(Req, {Proc, _DDocId}, Etag, FoldResult, StartFun, TotalRows) ->
    FoldResult2 = case FoldResult of
        {Limit, SkipCount, Response, RowAcc} ->
            {Limit, SkipCount, Response, RowAcc, nil};
        Else ->
            Else
    end,
    case FoldResult2 of
        {_, _, undefined, _, _} ->
            {ok, Resp, BeginBody} =
                render_head_for_empty_list(StartFun, Req, Etag, TotalRows),
            [<<"end">>, Chunks] = couch_query_servers:proc_prompt(Proc, [<<"list_end">>]),            
            Chunk = BeginBody ++ ?b2l(?l2b(Chunks)),
            send_non_empty_chunk(Resp, Chunk);
        {_, _, Resp, stop, _} ->
            ok;
        {_, _, Resp, _, _} ->
            [<<"end">>, Chunks] = couch_query_servers:proc_prompt(Proc, [<<"list_end">>]),
            send_non_empty_chunk(Resp, ?b2l(?l2b(Chunks)))
    end,
    last_chunk(Resp).


render_head_for_empty_list(StartListRespFun, Req, Etag, null) ->
    StartListRespFun(Req, Etag, []); % for reduce
render_head_for_empty_list(StartListRespFun, Req, Etag, TotalRows) ->
    StartListRespFun(Req, Etag, TotalRows, null, []).


% Maybe this is in the proplists API
% todo move to couch_util
json_apply_field(H, {L}) ->
    json_apply_field(H, L, []).
json_apply_field({Key, NewValue}, [{Key, _OldVal} | Headers], Acc) ->
    % drop matching keys
    json_apply_field({Key, NewValue}, Headers, Acc);
json_apply_field({Key, NewValue}, [{OtherKey, OtherVal} | Headers], Acc) ->
    % something else is next, leave it alone.
    json_apply_field({Key, NewValue}, Headers, [{OtherKey, OtherVal} | Acc]);
json_apply_field({Key, NewValue}, [], Acc) ->
    % end of list, add ours
    {[{Key, NewValue}|Acc]}.

apply_etag({ExternalResponse}, CurrentEtag) ->
    % Here we embark on the delicate task of replacing or creating the
    % headers on the JsonResponse object. We need to control the Etag and
    % Vary headers. If the external function controls the Etag, we'd have to
    % run it to check for a match, which sort of defeats the purpose.
    case proplists:get_value(<<"headers">>, ExternalResponse, nil) of
    nil ->
        % no JSON headers
        % add our Etag and Vary headers to the response
        {[{<<"headers">>, {[{<<"Etag">>, CurrentEtag}, {<<"Vary">>, <<"Accept">>}]}} | ExternalResponse]};
    JsonHeaders ->
        {[case Field of
        {<<"headers">>, JsonHeaders} -> % add our headers
            JsonHeadersEtagged = json_apply_field({<<"Etag">>, CurrentEtag}, JsonHeaders),
            JsonHeadersVaried = json_apply_field({<<"Vary">>, <<"Accept">>}, JsonHeadersEtagged),
            {<<"headers">>, JsonHeadersVaried};
        _ -> % skip non-header fields
            Field
        end || Field <- ExternalResponse]}
    end.

