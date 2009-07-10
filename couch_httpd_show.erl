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

-module(couch_httpd_show).

-export([handle_doc_show_req/2, handle_view_list_req/2,
        handle_doc_show/5, handle_view_list/6]).


-include("couch_db.hrl").

-import(couch_httpd,
    [send_json/2,send_json/3,send_json/4,send_method_not_allowed/2,
    start_json_response/2,send_chunk/2,send_chunked_error/2,
    start_chunked_response/3, send_error/4]).

handle_doc_show_req(#httpd{
        method='GET',
        path_parts=[_DbName, _Design, DesignName, _Show, ShowName, DocId]
    }=Req, Db) ->
    handle_doc_show(Req, DesignName, ShowName, DocId, Db);
        
handle_doc_show_req(#httpd{
        method='GET',
        path_parts=[_DbName, _Design, DesignName, _Show, ShowName]
    }=Req, Db) ->
    handle_doc_show(Req, DesignName, ShowName, nil, Db);

handle_doc_show_req(#httpd{method='GET'}=Req, _Db) ->
    send_error(Req, 404, <<"show_error">>, <<"Invalid path.">>);

handle_doc_show_req(Req, _Db) ->
    send_method_not_allowed(Req, "GET,HEAD").
    
handle_doc_show(Req, DesignName, ShowName, DocId, Db) ->
    DesignId = <<"_design/", DesignName/binary>>,
    #doc{body={Props}} = couch_httpd_db:couch_doc_open(Db, DesignId, nil, []),
    Lang = proplists:get_value(<<"language">>, Props, <<"javascript">>),
    ShowSrc = get_nested_json_value({Props}, [<<"shows">>, ShowName]),
    Doc = case DocId of
        nil -> nil;
        _ ->
        try couch_httpd_db:couch_doc_open(Db, DocId, nil, [conflicts]) of
            FoundDoc -> FoundDoc
        catch
            _ -> nil
        end
    end,
    send_doc_show_response(Lang, ShowSrc, DocId, Doc, Req, Db).
    
handle_view_list_req(#httpd{method='GET',
        path_parts=[_DbName, _Design, DesignName, _List, ListName, ViewName]}=Req, Db) ->
    handle_view_list(Req, DesignName, ListName, ViewName, Db, nil);

handle_view_list_req(#httpd{method='GET'}=Req, _Db) ->
    send_error(Req, 404, <<"list_error">>, <<"Invalid path.">>);

handle_view_list_req(#httpd{method='POST',
        path_parts=[_DbName, _Design, DesignName, _List, ListName, ViewName]}=Req, Db) ->
    ReqBody = couch_httpd:body(Req),
    {Props2} = ?JSON_DECODE(ReqBody),
    Keys = proplists:get_value(<<"keys">>, Props2, nil),
    handle_view_list(Req#httpd{req_body=ReqBody}, DesignName, ListName, ViewName, Db, Keys);

handle_view_list_req(Req, _Db) ->
    send_method_not_allowed(Req, "GET,POST,HEAD").

handle_view_list(Req, DesignName, ListName, ViewName, Db, Keys) ->
    DesignId = <<"_design/", DesignName/binary>>,
    #doc{body={Props}} = couch_httpd_db:couch_doc_open(Db, DesignId, nil, []),
    Lang = proplists:get_value(<<"language">>, Props, <<"javascript">>),
    ListSrc = get_nested_json_value({Props}, [<<"lists">>, ListName]),
    send_view_list_response(Lang, ListSrc, ViewName, DesignId, Req, Db, Keys).

get_nested_json_value({Props}, [Key|Keys]) ->
    case proplists:get_value(Key, Props, nil) of
    nil -> throw({not_found, <<"missing json key: ", Key/binary>>});
    Value -> get_nested_json_value(Value, Keys)
    end;
get_nested_json_value(Value, []) ->
    Value;
get_nested_json_value(_NotJSONObj, _) ->
    throw({not_found, json_mismatch}).

send_view_list_response(Lang, ListSrc, ViewName, DesignId, Req, Db, Keys) ->
    Stale = couch_httpd_view:get_stale_type(Req),
    Reduce = couch_httpd_view:get_reduce_type(Req),
    case couch_view:get_map_view(Db, DesignId, ViewName, Stale) of
    {ok, View, Group} ->
        QueryArgs = couch_httpd_view:parse_view_params(Req, Keys, map),
        output_map_list(Req, Lang, ListSrc, View, Group, Db, QueryArgs, Keys);
    {not_found, _Reason} ->
        case couch_view:get_reduce_view(Db, DesignId, ViewName, Stale) of
        {ok, ReduceView, Group} ->
            case Reduce of
            false ->
                QueryArgs = couch_httpd_view:parse_view_params(
                    Req, Keys, map_red
                ),
                MapView = couch_view:extract_map_view(ReduceView),
                output_map_list(Req, Lang, ListSrc, MapView, Group, Db, QueryArgs, Keys);
            _ ->
                QueryArgs = couch_httpd_view:parse_view_params(
                    Req, Keys, reduce
                ),
                output_reduce_list(Req, Lang, ListSrc, ReduceView, Group, Db, QueryArgs, Keys)
            end;
        {not_found, Reason} ->
            throw({not_found, Reason})
        end
    end.


output_map_list(#httpd{mochi_req=MReq}=Req, Lang, ListSrc, View, Group, Db, QueryArgs, nil) ->
    #view_query_args{
        limit = Limit,
        direction = Dir,
        skip = SkipCount,
        start_key = StartKey,
        start_docid = StartDocId
    } = QueryArgs,
    {ok, RowCount} = couch_view:get_row_count(View),
    Start = {StartKey, StartDocId},
    Headers = MReq:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    Accept = proplists:get_value('Accept', Hlist),
    CurrentEtag = couch_httpd_view:view_group_etag(Group, {Lang, ListSrc, Accept}),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        % get the os process here
        % pass it into the view fold with closures
        {ok, QueryServer} = couch_query_servers:start_view_list(Lang, ListSrc),

        StartListRespFun = make_map_start_resp_fun(QueryServer, Db),
        SendListRowFun = make_map_send_row_fun(QueryServer),

        FoldlFun = couch_httpd_view:make_view_fold_fun(Req, QueryArgs, CurrentEtag, Db, RowCount,
            #view_fold_helper_funs{
                reduce_count = fun couch_view:reduce_to_count/1,
                start_response = StartListRespFun,
                send_row = SendListRowFun
            }),
        FoldAccInit = {Limit, SkipCount, undefined, [], nil},
        {ok, FoldResult} = couch_view:fold(View, Start, Dir, FoldlFun, FoldAccInit),
        finish_list(Req, QueryServer, CurrentEtag, FoldResult, StartListRespFun, RowCount)
    end);

output_map_list(#httpd{mochi_req=MReq}=Req, Lang, ListSrc, View, Group, Db, QueryArgs, Keys) ->
    #view_query_args{
        limit = Limit,
        direction = Dir,
        skip = SkipCount,
        start_docid = StartDocId
    } = QueryArgs,
    {ok, RowCount} = couch_view:get_row_count(View),
    Headers = MReq:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    Accept = proplists:get_value('Accept', Hlist),
    CurrentEtag = couch_httpd_view:view_group_etag(Group, {Lang, ListSrc, Accept}),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        % get the os process here
        % pass it into the view fold with closures
        {ok, QueryServer} = couch_query_servers:start_view_list(Lang, ListSrc),

        StartListRespFun = make_map_start_resp_fun(QueryServer, Db),
        SendListRowFun = make_map_send_row_fun(QueryServer),

        FoldAccInit = {Limit, SkipCount, undefined, [], nil},
        {ok, FoldResult} = lists:foldl(
            fun(Key, {ok, FoldAcc}) ->
                FoldlFun = couch_httpd_view:make_view_fold_fun(Req, QueryArgs#view_query_args{
                        start_key = Key,
                        end_key = Key
                    }, CurrentEtag, Db, RowCount,
                    #view_fold_helper_funs{
                        reduce_count = fun couch_view:reduce_to_count/1,
                        start_response = StartListRespFun,
                        send_row = SendListRowFun
                    }),
                couch_view:fold(View, {Key, StartDocId}, Dir, FoldlFun, FoldAcc)
            end, {ok, FoldAccInit}, Keys),
        finish_list(Req, QueryServer, CurrentEtag, FoldResult, StartListRespFun, RowCount)
    end).

make_map_start_resp_fun(QueryServer, Db) ->
    fun(Req, Etag, TotalRows, Offset, _Acc) ->
        Head = {[{<<"total_rows">>, TotalRows}, {<<"offset">>, Offset}]},
        start_list_resp(QueryServer, Req, Db, Head, Etag)
    end.

make_reduce_start_resp_fun(QueryServer, _Req, Db, _CurrentEtag) ->
    fun(Req2, Etag, _Acc) ->
        start_list_resp(QueryServer, Req2, Db, {[]}, Etag)
    end.

start_list_resp(QueryServer, Req, Db, Head, Etag) ->
    [<<"start">>,Chunks,JsonResp] = couch_query_servers:render_list_head(QueryServer,
        Req, Db, Head),
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
    fun(Resp, Db, Row, _IncludeDocs, RowFront) ->
        send_list_row(Resp, QueryServer, Db, Row, RowFront)
    end.

make_reduce_send_row_fun(QueryServer, Db) ->
    fun(Resp, Row, RowFront) ->
        send_list_row(Resp, QueryServer, Db, Row, RowFront)
    end.

send_list_row(Resp, QueryServer, Db, Row, RowFront) ->
    try
        [Go,Chunks] = couch_query_servers:render_list_row(QueryServer, Db, Row),
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

send_non_empty_chunk(Resp, Chunk) ->
    case Chunk of
        [] -> ok;
        _ -> send_chunk(Resp, Chunk)
    end.

output_reduce_list(#httpd{mochi_req=MReq}=Req, Lang, ListSrc, View, Group, Db, QueryArgs, nil) ->
    #view_query_args{
        limit = Limit,
        direction = Dir,
        skip = SkipCount,
        start_key = StartKey,
        start_docid = StartDocId,
        end_key = EndKey,
        end_docid = EndDocId,
        group_level = GroupLevel
    } = QueryArgs,
    % get the os process here
    % pass it into the view fold with closures
    {ok, QueryServer} = couch_query_servers:start_view_list(Lang, ListSrc),
    Headers = MReq:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    Accept = proplists:get_value('Accept', Hlist),
    CurrentEtag = couch_httpd_view:view_group_etag(Group, {Lang, ListSrc, Accept}),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        StartListRespFun = make_reduce_start_resp_fun(QueryServer, Req, Db, CurrentEtag),
        SendListRowFun = make_reduce_send_row_fun(QueryServer, Db),

        {ok, GroupRowsFun, RespFun} = couch_httpd_view:make_reduce_fold_funs(Req,
            GroupLevel, QueryArgs, CurrentEtag,
            #reduce_fold_helper_funs{
                start_response = StartListRespFun,
                send_row = SendListRowFun
            }),
        FoldAccInit = {Limit, SkipCount, undefined, []},
        {ok, FoldResult} = couch_view:fold_reduce(View, Dir, {StartKey, StartDocId},
            {EndKey, EndDocId}, GroupRowsFun, RespFun,
            FoldAccInit),
        finish_list(Req, QueryServer, CurrentEtag, FoldResult, StartListRespFun, null)
    end);

output_reduce_list(#httpd{mochi_req=MReq}=Req, Lang, ListSrc, View, Group, Db, QueryArgs, Keys) ->
    #view_query_args{
        limit = Limit,
        direction = Dir,
        skip = SkipCount,
        start_docid = StartDocId,
        end_docid = EndDocId,
        group_level = GroupLevel
    } = QueryArgs,
    % get the os process here
    % pass it into the view fold with closures
    {ok, QueryServer} = couch_query_servers:start_view_list(Lang, ListSrc),
    Headers = MReq:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    Accept = proplists:get_value('Accept', Hlist),
    CurrentEtag = couch_httpd_view:view_group_etag(Group, {Lang, ListSrc, Accept, Keys}),

    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        StartListRespFun = make_reduce_start_resp_fun(QueryServer, Req, Db, CurrentEtag),
        SendListRowFun = make_reduce_send_row_fun(QueryServer, Db),

        {ok, GroupRowsFun, RespFun} = couch_httpd_view:make_reduce_fold_funs(Req,
            GroupLevel, QueryArgs, CurrentEtag,
            #reduce_fold_helper_funs{
                start_response = StartListRespFun,
                send_row = SendListRowFun
            }),
        FoldAccInit = {Limit, SkipCount, undefined, []},
        {ok, FoldResult} = lists:foldl(
            fun(Key, {ok, FoldAcc}) ->
                couch_view:fold_reduce(View, Dir, {Key, StartDocId},
                    {Key, EndDocId}, GroupRowsFun, RespFun, FoldAcc)
            end, {ok, FoldAccInit}, Keys),
        finish_list(Req, QueryServer, CurrentEtag, FoldResult, StartListRespFun, null)
    end).

finish_list(Req, QueryServer, Etag, FoldResult, StartFun, TotalRows) ->
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
            [<<"end">>, Chunks] = couch_query_servers:render_list_tail(QueryServer),
            Chunk = BeginBody ++ ?b2l(?l2b(Chunks)),
            send_non_empty_chunk(Resp, Chunk);
        {_, _, Resp, stop, _} ->
            ok;
        {_, _, Resp, _, _} ->
            [<<"end">>, Chunks] = couch_query_servers:render_list_tail(QueryServer),
            send_non_empty_chunk(Resp, ?b2l(?l2b(Chunks)))
    end,
    send_chunk(Resp, []).

render_head_for_empty_list(StartListRespFun, Req, Etag, null) ->
    StartListRespFun(Req, Etag, []); % for reduce
render_head_for_empty_list(StartListRespFun, Req, Etag, TotalRows) ->
    StartListRespFun(Req, Etag, TotalRows, null, []).

send_doc_show_response(Lang, ShowSrc, DocId, nil, #httpd{mochi_req=MReq}=Req, Db) ->
    % compute etag with no doc
    Headers = MReq:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    Accept = proplists:get_value('Accept', Hlist),
    CurrentEtag = couch_httpd:make_etag({Lang, ShowSrc, nil, Accept}),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        [<<"resp">>, ExternalResp] = couch_query_servers:render_doc_show(Lang, ShowSrc,
            DocId, nil, Req, Db),
        JsonResp = apply_etag(ExternalResp, CurrentEtag),
        couch_httpd_external:send_external_response(Req, JsonResp)
    end);

send_doc_show_response(Lang, ShowSrc, DocId, #doc{revs=Revs}=Doc, #httpd{mochi_req=MReq}=Req, Db) ->
    % calculate the etag
    Headers = MReq:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    Accept = proplists:get_value('Accept', Hlist),
    CurrentEtag = couch_httpd:make_etag({Lang, ShowSrc, Revs, Accept}),
    % We know our etag now
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        [<<"resp">>, ExternalResp] = couch_query_servers:render_doc_show(Lang, ShowSrc,
            DocId, Doc, Req, Db),
        JsonResp = apply_etag(ExternalResp, CurrentEtag),
        couch_httpd_external:send_external_response(Req, JsonResp)
    end).

set_or_replace_header(H, L) ->
    set_or_replace_header(H, L, []).

set_or_replace_header({Key, NewValue}, [{Key, _OldVal} | Headers], Acc) ->
    % drop matching keys
    set_or_replace_header({Key, NewValue}, Headers, Acc);
set_or_replace_header({Key, NewValue}, [{OtherKey, OtherVal} | Headers], Acc) ->
    % something else is next, leave it alone.
    set_or_replace_header({Key, NewValue}, Headers, [{OtherKey, OtherVal} | Acc]);
set_or_replace_header({Key, NewValue}, [], Acc) ->
    % end of list, add ours
    [{Key, NewValue}|Acc].

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
    {JsonHeaders} ->
        {[case Field of
        {<<"headers">>, {JsonHeaders}} -> % add our headers
            JsonHeadersEtagged = set_or_replace_header({<<"Etag">>, CurrentEtag}, JsonHeaders),
            JsonHeadersVaried = set_or_replace_header({<<"Vary">>, <<"Accept">>}, JsonHeadersEtagged),
            {<<"headers">>, {JsonHeadersVaried}};
        _ -> % skip non-header fields
            Field
        end || Field <- ExternalResponse]}
    end.

