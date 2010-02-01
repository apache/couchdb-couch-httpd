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

-module(couch_query_servers).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2,code_change/3,stop/0]).
-export([start_doc_map/2, map_docs/2, stop_doc_map/1]).
-export([reduce/3, rereduce/3,validate_doc_update/5]).
-export([filter_docs/5]).

-export([with_ddoc_proc/2, proc_prompt/2, ddoc_prompt/3, ddoc_proc_prompt/3, json_doc/1]).

% -export([test/0]).

-include("couch_db.hrl").

-record(proc, {
    pid,
    lang,
    ddoc_keys = [],
    prompt_fun,
    set_timeout_fun,
    stop_fun
}).

start_link() ->
    gen_server:start_link({local, couch_query_servers}, couch_query_servers, [], []).

stop() ->
    exit(whereis(couch_query_servers), normal).

start_doc_map(Lang, Functions) ->
    Proc = get_os_process(Lang),
    lists:foreach(fun(FunctionSource) ->
        true = proc_prompt(Proc, [<<"add_fun">>, FunctionSource])
    end, Functions),
    {ok, Proc}.

map_docs(Proc, Docs) ->
    % send the documents
    Results = lists:map(
        fun(Doc) ->
            Json = couch_doc:to_json_obj(Doc, []),

            FunsResults = proc_prompt(Proc, [<<"map_doc">>, Json]),
            % the results are a json array of function map yields like this:
            % [FunResults1, FunResults2 ...]
            % where funresults is are json arrays of key value pairs:
            % [[Key1, Value1], [Key2, Value2]]
            % Convert the key, value pairs to tuples like
            % [{Key1, Value1}, {Key2, Value2}]
            lists:map(
                fun(FunRs) ->
                    [list_to_tuple(FunResult) || FunResult <- FunRs]
                end,
            FunsResults)
        end,
        Docs),
    {ok, Results}.


stop_doc_map(nil) ->
    ok;
stop_doc_map(Proc) ->
    ok = ret_os_process(Proc).

group_reductions_results([]) ->
    [];
group_reductions_results(List) ->
    {Heads, Tails} = lists:foldl(
        fun([H|T], {HAcc,TAcc}) ->
            {[H|HAcc], [T|TAcc]}
        end, {[], []}, List),
    case Tails of
    [[]|_] -> % no tails left
        [Heads];
    _ ->
     [Heads | group_reductions_results(Tails)]
    end.

rereduce(_Lang, [], _ReducedValues) ->
    {ok, []};
rereduce(Lang, RedSrcs, ReducedValues) ->
    Grouped = group_reductions_results(ReducedValues),    
    Results = lists:zipwith(
        fun
        (<<"_", _/binary>> = FunSrc, Values) ->
            {ok, [Result]} = builtin_reduce(rereduce, [FunSrc], [[[], V] || V <- Values], []),
            Result;
        (FunSrc, Values) ->
            os_rereduce(Lang, [FunSrc], Values)
        end, RedSrcs, Grouped),
    {ok, Results}.

reduce(_Lang, [], _KVs) ->
    {ok, []};
reduce(Lang, RedSrcs, KVs) ->
    {OsRedSrcs, BuiltinReds} = lists:partition(fun
        (<<"_", _/binary>>) -> false;
        (_OsFun) -> true
    end, RedSrcs),
    {ok, OsResults} = os_reduce(Lang, OsRedSrcs, KVs),
    {ok, BuiltinResults} = builtin_reduce(reduce, BuiltinReds, KVs, []),
    recombine_reduce_results(RedSrcs, OsResults, BuiltinResults, []).

recombine_reduce_results([], [], [], Acc) ->
    {ok, lists:reverse(Acc)};
recombine_reduce_results([<<"_", _/binary>>|RedSrcs], OsResults, [BRes|BuiltinResults], Acc) ->
    recombine_reduce_results(RedSrcs, OsResults, BuiltinResults, [BRes|Acc]);
recombine_reduce_results([_OsFun|RedSrcs], [OsR|OsResults], BuiltinResults, Acc) ->
    recombine_reduce_results(RedSrcs, OsResults, BuiltinResults, [OsR|Acc]).

os_reduce(_Lang, [], _KVs) ->
    {ok, []};
os_reduce(Lang, OsRedSrcs, KVs) ->
    Proc = get_os_process(Lang),
    OsResults = try proc_prompt(Proc, [<<"reduce">>, OsRedSrcs, KVs]) of
        [true, Reductions] -> Reductions
    after
        ok = ret_os_process(Proc)
    end,
    {ok, OsResults}.

os_rereduce(_Lang, [], _KVs) ->
    {ok, []};
os_rereduce(Lang, OsRedSrcs, KVs) ->
    Proc = get_os_process(Lang),
    try proc_prompt(Proc, [<<"rereduce">>, OsRedSrcs, KVs]) of
        [true, [Reduction]] -> Reduction
    after
        ok = ret_os_process(Proc)
    end.


builtin_reduce(_Re, [], _KVs, Acc) ->
    {ok, lists:reverse(Acc)};
builtin_reduce(Re, [<<"_sum">>|BuiltinReds], KVs, Acc) ->
    Sum = builtin_sum_rows(KVs),
    builtin_reduce(Re, BuiltinReds, KVs, [Sum|Acc]);
builtin_reduce(reduce, [<<"_count">>|BuiltinReds], KVs, Acc) ->
    Count = length(KVs),
    builtin_reduce(reduce, BuiltinReds, KVs, [Count|Acc]);
builtin_reduce(rereduce, [<<"_count">>|BuiltinReds], KVs, Acc) ->
    Count = builtin_sum_rows(KVs),
    builtin_reduce(rereduce, BuiltinReds, KVs, [Count|Acc]).

builtin_sum_rows(KVs) ->
    lists:foldl(fun
        ([_Key, Value], Acc) when is_number(Value) ->
            Acc + Value;
        (_Else, _Acc) ->
            throw({invalid_value, <<"builtin _sum function requires map values to be numbers">>})
    end, 0, KVs).


% use the function stored in ddoc.validate_doc_update to test an update.
validate_doc_update(DDoc, EditDoc, DiskDoc, Ctx, SecObj) ->
    JsonEditDoc = couch_doc:to_json_obj(EditDoc, [revs]),
    JsonDiskDoc = json_doc(DiskDoc),  
    case ddoc_prompt(DDoc, [<<"validate_doc_update">>], [JsonEditDoc, JsonDiskDoc, Ctx, SecObj]) of
        1 ->
            ok;
        {[{<<"forbidden">>, Message}]} ->
            throw({forbidden, Message});
        {[{<<"unauthorized">>, Message}]} ->
            throw({unauthorized, Message})
    end.

json_doc(nil) -> null;
json_doc(Doc) ->
    couch_doc:to_json_obj(Doc, [revs]).

filter_docs(Req, Db, DDoc, FName, Docs) ->
    JsonReq = couch_httpd_external:json_req_obj(Req, Db),
    JsonDocs = [couch_doc:to_json_obj(Doc, [revs]) || Doc <- Docs],
    JsonCtx = couch_util:json_user_ctx(Db),
    [true, Passes] = ddoc_prompt(DDoc, [<<"filters">>, FName], [JsonDocs, JsonReq, JsonCtx]),
    {ok, Passes}.

ddoc_proc_prompt({Proc, DDocId}, FunPath, Args) -> 
    proc_prompt(Proc, [<<"ddoc">>, DDocId, FunPath, Args]).

ddoc_prompt(DDoc, FunPath, Args) ->
    with_ddoc_proc(DDoc, fun({Proc, DDocId}) ->
        proc_prompt(Proc, [<<"ddoc">>, DDocId, FunPath, Args])
    end).

with_ddoc_proc(#doc{id=DDocId,revs={Start, [DiskRev|_]}}=DDoc, Fun) ->
    Rev = couch_doc:rev_to_str({Start, DiskRev}),
    DDocKey = {DDocId, Rev},
    Proc = get_ddoc_process(DDoc, DDocKey),
    try Fun({Proc, DDocId})
    after
        ok = ret_os_process(Proc)
    end.

init([]) ->
    % read config and register for configuration changes

    % just stop if one of the config settings change. couch_server_sup
    % will restart us and then we will pick up the new settings.

    ok = couch_config:register(
        fun("query_servers" ++ _, _) ->
            ?MODULE:stop()
        end),
    ok = couch_config:register(
        fun("native_query_servers" ++ _, _) ->
            ?MODULE:stop()
        end),

    Langs = ets:new(couch_query_server_langs, [set, private]),
    PidProcs = ets:new(couch_query_server_pid_langs, [set, private]),
    LangProcs = ets:new(couch_query_server_procs, [set, private]),
    InUse = ets:new(couch_query_server_used, [set, private]),
    % 'query_servers' specifies an OS command-line to execute.
    lists:foreach(fun({Lang, Command}) ->
        true = ets:insert(Langs, {?l2b(Lang),
                          couch_os_process, start_link, [Command]})
    end, couch_config:get("query_servers")),
    % 'native_query_servers' specifies a {Module, Func, Arg} tuple.
    lists:foreach(fun({Lang, SpecStr}) ->
        {ok, {Mod, Fun, SpecArg}} = couch_util:parse_term(SpecStr),
        true = ets:insert(Langs, {?l2b(Lang),
                          Mod, Fun, SpecArg})
    end, couch_config:get("native_query_servers")),
    process_flag(trap_exit, true),
    {ok, {Langs, % Keyed by language name, value is {Mod,Func,Arg}
          PidProcs, % Keyed by PID, valus is a #proc record.
          LangProcs, % Keyed by language name, value is a #proc record
          InUse % Keyed by PID, value is #proc record.
          }}.

terminate(_Reason, _Server) ->
    ok.

handle_call({get_proc, #doc{body={Props}}=DDoc, DDocKey}, _From, {Langs, PidProcs, LangProcs, InUse}=Server) ->
    % Note to future self. Add max process limit.
    Lang = proplists:get_value(<<"language">>, Props, <<"javascript">>),    
    case ets:lookup(LangProcs, Lang) of
    [{Lang, [P|Rest]}] ->
        % find a proc in the set that has the DDoc
        case proc_with_ddoc(DDoc, DDocKey, [P|Rest]) of
            {ok, Proc} ->
                % looks like the proc isn't getting dropped from the list.
                % we need to change this to take a fun for equality checking
                % so we can do a comparison on portnum
                rem_from_list(LangProcs, Lang, Proc),
                add_to_list(InUse, Lang, Proc),
                {reply, {ok, Proc, get_query_server_config()}, Server};
            Error -> 
                {reply, Error, Server}
            end;
    _ ->
        case (catch new_process(Langs, Lang)) of
        {ok, Proc} ->
            add_value(PidProcs, Proc#proc.pid, Proc),
            case proc_with_ddoc(DDoc, DDocKey, [Proc]) of
                {ok, Proc2} ->
                    rem_from_list(LangProcs, Lang, Proc),
                    add_to_list(InUse, Lang, Proc2),
                    {reply, {ok, Proc2, get_query_server_config()}, Server};
                Error -> 
                    {reply, Error, Server}
                end;
        Error ->
            {reply, Error, Server}
        end
    end;
handle_call({get_proc, Lang}, _From, {Langs, PidProcs, LangProcs, InUse}=Server) ->
    % Note to future self. Add max process limit.
    case ets:lookup(LangProcs, Lang) of
    [{Lang, [Proc|_]}] ->
        add_value(PidProcs, Proc#proc.pid, Proc),
        rem_from_list(LangProcs, Lang, Proc),
        add_to_list(InUse, Lang, Proc),
        {reply, {ok, Proc, get_query_server_config()}, Server};
    _ ->
        case (catch new_process(Langs, Lang)) of
        {ok, Proc} ->
            add_value(PidProcs, Proc#proc.pid, Proc),
            add_to_list(InUse, Lang, Proc),
            {reply, {ok, Proc, get_query_server_config()}, Server};
        Error ->
            {reply, Error, Server}
        end
    end;
handle_call({ret_proc, Proc}, _From, {_, _, LangProcs, InUse}=Server) ->
    % Along with max process limit, here we should check
    % if we're over the limit and discard when we are.
    add_to_list(LangProcs, Proc#proc.lang, Proc),
    rem_from_list(InUse, Proc#proc.lang, Proc),
    {reply, true, Server}.

handle_cast(_Whatever, Server) ->
    {noreply, Server}.

handle_info({'EXIT', Pid, Status}, {_, PidProcs, LangProcs, InUse}=Server) ->
    case ets:lookup(PidProcs, Pid) of
    [{Pid, Proc}] ->
        case Status of
        normal -> ok;
        _ -> ?LOG_DEBUG("Linked process died abnormally: ~p (reason: ~p)", [Pid, Status])
        end,
        rem_value(PidProcs, Pid),
        catch rem_from_list(LangProcs, Proc#proc.lang, Proc),
        catch rem_from_list(InUse, Proc#proc.lang, Proc),
        {noreply, Server};
    [] ->
        ?LOG_DEBUG("Unknown linked process died: ~p (reason: ~p)", [Pid, Status]),
        {stop, Status, Server}
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% Private API

get_query_server_config() ->
    ReduceLimit = list_to_atom(
        couch_config:get("query_server_config","reduce_limit","true")),
    {[{<<"reduce_limit">>, ReduceLimit}]}.

new_process(Langs, Lang) ->
    case ets:lookup(Langs, Lang) of
    [{Lang, Mod, Func, Arg}] ->
        {ok, Pid} = apply(Mod, Func, Arg),
        {ok, #proc{lang=Lang,
                   pid=Pid,
                   % Called via proc_prompt, proc_set_timeout, and proc_stop
                   prompt_fun={Mod, prompt},
                   set_timeout_fun={Mod, set_timeout},
                   stop_fun={Mod, stop}}};
    _ ->
        {unknown_query_language, Lang}
    end.

proc_with_ddoc(DDoc, DDocKey, LangProcs) ->
    DDocProcs = lists:filter(fun(#proc{ddoc_keys=Keys}) -> 
            lists:any(fun(Key) ->
                Key == DDocKey
            end, Keys)
        end, LangProcs),
    case DDocProcs of
        [DDocProc|_] ->
            ?LOG_DEBUG("DDocProc found for DDocKey: ~p",[DDocKey]),
            {ok, DDocProc};
        [] ->
            [TeachProc|_] = LangProcs,
            ?LOG_DEBUG("Teach ddoc to new proc ~p with DDocKey: ~p",[TeachProc, DDocKey]),
            {ok, SmartProc} = teach_ddoc(DDoc, DDocKey, TeachProc),
            {ok, SmartProc}
    end.

proc_prompt(Proc, Args) ->
    {Mod, Func} = Proc#proc.prompt_fun,
    apply(Mod, Func, [Proc#proc.pid, Args]).

proc_stop(Proc) ->
    {Mod, Func} = Proc#proc.stop_fun,
    apply(Mod, Func, [Proc#proc.pid]).

proc_set_timeout(Proc, Timeout) ->
    {Mod, Func} = Proc#proc.set_timeout_fun,
    apply(Mod, Func, [Proc#proc.pid, Timeout]).

teach_ddoc(DDoc, {DDocId, _Rev}=DDocKey, #proc{ddoc_keys=Keys}=Proc) ->
    % send ddoc over the wire
    % we only share the rev with the client we know to update code
    % but it only keeps the latest copy, per each ddoc, around.
    true = proc_prompt(Proc, [<<"ddoc">>, <<"new">>, DDocId, couch_doc:to_json_obj(DDoc, [])]),
    % we should remove any other ddocs keys for this docid
    % because the query server overwrites without the rev
    Keys2 = [{D,R} || {D,R} <- Keys, D /= DDocId],
    % add ddoc to the proc
    {ok, Proc#proc{ddoc_keys=[DDocKey|Keys2]}}.

get_ddoc_process(#doc{} = DDoc, DDocKey) ->
    % remove this case statement
    case gen_server:call(couch_query_servers, {get_proc, DDoc, DDocKey}) of
    {ok, Proc, QueryConfig} ->
        % process knows the ddoc
        case (catch proc_prompt(Proc, [<<"reset">>, QueryConfig])) of
        true ->
            proc_set_timeout(Proc, list_to_integer(couch_config:get(
                                "couchdb", "os_process_timeout", "5000"))),
            link(Proc#proc.pid),
            Proc;
        _ ->
            catch proc_stop(Proc),
            get_ddoc_process(DDoc, DDocKey)
        end;
    Error ->
        throw(Error)
    end.

get_os_process(Lang) ->
    case gen_server:call(couch_query_servers, {get_proc, Lang}) of
    {ok, Proc, QueryConfig} ->
        case (catch proc_prompt(Proc, [<<"reset">>, QueryConfig])) of
        true ->
            proc_set_timeout(Proc, list_to_integer(couch_config:get(
                                "couchdb", "os_process_timeout", "5000"))),
            link(Proc#proc.pid),
            Proc;
        _ ->
            catch proc_stop(Proc),
            get_os_process(Lang)
        end;
    Error ->
        throw(Error)
    end.

ret_os_process(Proc) ->
    true = gen_server:call(couch_query_servers, {ret_proc, Proc}),
    catch unlink(Proc#proc.pid),
    ok.

add_value(Tid, Key, Value) ->
    true = ets:insert(Tid, {Key, Value}).

rem_value(Tid, Key) ->
    true = ets:delete(Tid, Key).

add_to_list(Tid, Key, Value) ->
    case ets:lookup(Tid, Key) of
    [{Key, Vals}] ->
        true = ets:insert(Tid, {Key, [Value|Vals]});
    [] ->
        true = ets:insert(Tid, {Key, [Value]})
    end.

rem_from_list(Tid, Key, Value) when is_record(Value, proc)->
    Pid = Value#proc.pid,
    case ets:lookup(Tid, Key) of
    [{Key, Vals}] ->
        % make a new values list that doesn't include the Value arg
        NewValues = [Val || #proc{pid=P}=Val <- Vals, P /= Pid],
        ets:insert(Tid, {Key, NewValues});
    [] -> ok
    end;
rem_from_list(Tid, Key, Value) ->
    case ets:lookup(Tid, Key) of
    [{Key, Vals}] ->
        % make a new values list that doesn't include the Value arg
        NewValues = [Val || Val <- Vals, Val /= Value],
        ets:insert(Tid, {Key, NewValues});
    [] -> ok
    end.
