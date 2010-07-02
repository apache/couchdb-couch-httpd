% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.
%
% bind_path is based on bind method from Webmachine


%% @doc Module for URL rewriting by pattern matching.

-module(chttpd_rewrite).
-export([handle_rewrite_req/3]).
-include("chttpd.hrl").

-define(SEPARATOR, $\/).
-define(MATCH_ALL, '*').


%% doc The http rewrite handler. All rewriting is done from
%% /dbname/_design/ddocname/_rewrite by default.
%%
%% each rules should be in rewrites member of the design doc.
%% Ex of a complete rule :
%%
%%  {
%%      ....
%%      "rewrites": [
%%      {
%%          "from": "",
%%          "to": "index.html",
%%          "method": "GET",
%%          "query": {}
%%      }
%%      ]
%%  }
%%
%%  from: is the path rule used to bind current uri to the rule. It
%% use pattern matching for that.
%%
%%  to: rule to rewrite an url. It can contain variables depending on binding
%% variables discovered during pattern matching and query args (url args and from
%% the query member.)
%%
%%  method: method to bind the request method to the rule. by default "*"
%%  query: query args you want to define they can contain dynamic variable
%% by binding the key to the bindings
%%
%%
%% to and from are path with  patterns. pattern can be string starting with ":" or
%% "*". ex:
%% /somepath/:var/*
%%
%% This path is converted in erlang list by splitting "/". Each var are
%% converted in atom. "*" is converted to '*' atom. The pattern matching is done
%% by splitting "/" in request url in a list of token. A string pattern will
%% match equal token. The star atom ('*' in single quotes) will match any number
%% of tokens, but may only be present as the last pathtern in a pathspec. If all
%% tokens are matched and all pathterms are used, then the pathspec matches. It works
%% like webmachine. Each identified token will be reused in to rule and in query
%%
%% The pattern matching is done by first matching the request method to a rule. by
%% default all methods match a rule. (method is equal to "*" by default). Then
%% It will try to match the path to one rule. If no rule match, then a 404 error
%% is displayed.
%%
%% Once a rule is found we rewrite the request url using the "to" and
%% "query" members. The identified token are matched to the rule and
%% will replace var. if '*' is found in the rule it will contain the remaining
%% part if it exists.
%%
%% Examples:
%%
%% Dispatch rule            URL             TO                  Tokens
%%
%% {"from": "/a/b",         /a/b?k=v        /some/b?k=v         var =:= b
%% "to": "/some/"}                                              k = v
%%
%% {"from": "/a/b",         /a/b            /some/b?var=b       var =:= b
%% "to": "/some/:var"}
%%
%% {"from": "/a",           /a              /some
%% "to": "/some/*"}
%%
%% {"from": "/a/*",         /a/b/c          /some/b/c
%% "to": "/some/*"}
%%
%% {"from": "/a",           /a              /some
%% "to": "/some/*"}
%%
%% {"from": "/a/:foo/*",    /a/b/c          /some/b/c?foo=b     foo =:= b
%% "to": "/some/:foo/*"}
%%
%% {"from": "/a/:foo",     /a/b             /some/?k=b&foo=b    foo =:= b
%% "to": "/some",
%%  "query": {
%%      "k": ":foo"
%%  }}
%%
%% {"from": "/a",           /a?foo=b        /some/b             foo =:= b
%% "to": "/some/:foo",
%%  }}



handle_rewrite_req(#httpd{
        path_parts=[DbName, <<"_design">>, DesignName, _Rewrite|PathParts],
        method=Method,
        mochi_req=MochiReq}=Req, _Db, DDoc) ->

    % we are in a design handler
    DesignId = <<"_design/", DesignName/binary>>,
    Prefix = <<"/", DbName/binary, "/", DesignId/binary>>,
    QueryList = couch_httpd:qs(Req),
    QueryList1 = [{to_atom(K), V} || {K, V} <- QueryList],

    #doc{body={Props}} = DDoc,

    % get rules from ddoc
    case couch_util:get_value(<<"rewrites">>, Props) of
        undefined ->
            couch_httpd:send_error(Req, 404, <<"rewrite_error">>,
                            <<"Invalid path.">>);
        Rules ->
            % create dispatch list from rules
            DispatchList =  [make_rule(Rule) || {Rule} <- Rules],

            %% get raw path by matching url to a rule.
            RawPath = case try_bind_path(DispatchList, Method, PathParts,
                                    QueryList1) of
                no_dispatch_path ->
                    throw(not_found);
                {NewPathParts, Bindings} ->
                    Parts = [mochiweb_util:quote_plus(X) || X <- NewPathParts],

                    % build new path, reencode query args, eventually convert
                    % them to json
                    Path = lists:append(
                        string:join(Parts, [?SEPARATOR]),
                        case Bindings of
                            [] -> [];
                            _ -> [$?, encode_query(Bindings)]
                        end),
                    
                    % if path is relative detect it and rewrite path
                    case mochiweb_util:safe_relative_path(Path) of
                        undefined ->
                            ?b2l(Prefix) ++ "/" ++ Path;
                        P1 ->
                            ?b2l(Prefix) ++ "/" ++ P1
                    end

                end,

            % normalize final path (fix levels "." and "..")
            RawPath1 = ?b2l(iolist_to_binary(normalize_path(RawPath))),

            ?LOG_DEBUG("rewrite to ~p ~n", [RawPath1]),

            % build a new mochiweb request
            MochiReq1 = mochiweb_request:new(MochiReq:get(socket),
                                             MochiReq:get(method),
                                             RawPath1,
                                             MochiReq:get(version),
                                             MochiReq:get(headers)),

            % cleanup, It force mochiweb to reparse raw uri.
            MochiReq1:cleanup(),

            chttpd:handle_request(MochiReq1)
        end.



%% @doc Try to find a rule matching current url. If none is found
%% 404 error not_found is raised
try_bind_path([], _Method, _PathParts, _QueryList) ->
    no_dispatch_path;
try_bind_path([Dispatch|Rest], Method, PathParts, QueryList) ->
    [{PathParts1, Method1}, RedirectPath, QueryArgs] = Dispatch,
    case bind_method(Method1, Method) of
        true ->
            case bind_path(PathParts1, PathParts, []) of
                {ok, Remaining, Bindings} ->
                    Bindings1 = Bindings ++ QueryList,

                    % we parse query args from the rule and fill
                    % it eventually with bindings vars
                    QueryArgs1 = make_query_list(QueryArgs, Bindings1, []),
                    
                    % remove params in QueryLists1 that are already in
                    % QueryArgs1
                    Bindings2 = lists:foldl(fun({K, V}, Acc) ->
                        K1 = to_atom(K),
                        KV = case couch_util:get_value(K1, QueryArgs1) of
                            undefined -> [{K1, V}];
                            _V1 -> []
                        end,
                        Acc ++ KV
                    end, [], Bindings1),

                    FinalBindings = Bindings2 ++ QueryArgs1,
                    NewPathParts = make_new_path(RedirectPath, FinalBindings,
                                    Remaining, []),
                    {NewPathParts, FinalBindings};
                fail ->
                    try_bind_path(Rest, Method, PathParts, QueryList)
            end;
        false ->
            try_bind_path(Rest, Method, PathParts, QueryList)
    end.

%% rewriting dynamically the quey list given as query member in
%% rewrites. Each value is replaced by one binding or an argument
%% passed in url.
make_query_list([], _Bindings, Acc) ->
    Acc;
make_query_list([{Key, {Value}}|Rest], Bindings, Acc) ->
    Value1 = to_json({Value}),
    make_query_list(Rest, Bindings, [{to_atom(Key), Value1}|Acc]);
make_query_list([{Key, Value}|Rest], Bindings, Acc) when is_binary(Value) ->
    Value1 = replace_var(Key, Value, Bindings),
    make_query_list(Rest, Bindings, [{to_atom(Key), Value1}|Acc]);
make_query_list([{Key, Value}|Rest], Bindings, Acc) when is_list(Value) ->
    Value1 = replace_var(Key, Value, Bindings),
    make_query_list(Rest, Bindings, [{to_atom(Key), Value1}|Acc]);
make_query_list([{Key, Value}|Rest], Bindings, Acc) ->
    make_query_list(Rest, Bindings, [{to_atom(Key), Value}|Acc]).

replace_var(Key, Value, Bindings) ->
    case Value of
        <<":", Var/binary>> ->
            get_var(Var, Bindings, Value);
        _ when is_list(Value) ->
            Value1 = lists:foldr(fun(V, Acc) ->
                V1 = case V of
                    <<":", VName/binary>> ->
                        case get_var(VName, Bindings, V) of
                            V2 when is_list(V2) ->
                                iolist_to_binary(V2);
                            V2 -> V2
                        end;
                    _ ->
                        
                        V
                end,
                [V1|Acc]
            end, [], Value),
            to_json(Value1);
        _ when is_binary(Value) ->
            Value;
        _ ->
            case Key of
                <<"key">> -> to_json(Value);
                <<"startkey">> -> to_json(Value);
                <<"endkey">> -> to_json(Value);
                _ ->
                    lists:flatten(?JSON_ENCODE(Value))
            end
    end.


get_var(VarName, Props, Default) ->
    VarName1 = list_to_atom(binary_to_list(VarName)),
    couch_util:get_value(VarName1, Props, Default).

%% doc: build new patch from bindings. bindings are query args
%% (+ dynamic query rewritten if needed) and bindings found in
%% bind_path step.
make_new_path([], _Bindings, _Remaining, Acc) ->
    lists:reverse(Acc);
make_new_path([?MATCH_ALL], _Bindings, Remaining, Acc) ->
    Acc1 = lists:reverse(Acc) ++ Remaining,
    Acc1;
make_new_path([?MATCH_ALL|_Rest], _Bindings, Remaining, Acc) ->
    Acc1 = lists:reverse(Acc) ++ Remaining,
    Acc1;
make_new_path([P|Rest], Bindings, Remaining, Acc) when is_atom(P) ->
    P2 = case couch_util:get_value(P, Bindings) of
        undefined -> << "undefined">>;
        P1 -> P1
    end,
    make_new_path(Rest, Bindings, Remaining, [P2|Acc]);
make_new_path([P|Rest], Bindings, Remaining, Acc) ->
    make_new_path(Rest, Bindings, Remaining, [P|Acc]).


%% @doc If method of the query fith the rule method. If the
%% method rule is '*', which is the default, all
%% request method will bind. It allows us to make rules
%% depending on HTTP method.
bind_method(?MATCH_ALL, _Method) ->
    true;
bind_method(Method, Method) ->
    true;
bind_method(_, _) ->
    false.


%% @doc bind path. Using the rule from we try to bind variables given
%% to the current url by pattern matching
bind_path([], [], Bindings) ->
    {ok, [], Bindings};
bind_path([?MATCH_ALL], Rest, Bindings) when is_list(Rest) ->
    {ok, Rest, Bindings};
bind_path(_, [], _) ->
    fail;
bind_path([Token|RestToken],[Match|RestMatch],Bindings) when is_atom(Token) ->
    bind_path(RestToken, RestMatch, [{Token, Match}|Bindings]);
bind_path([Token|RestToken], [Token|RestMatch], Bindings) ->
    bind_path(RestToken, RestMatch, Bindings);
bind_path(_, _, _) ->
    fail.


%% normalize path.
normalize_path(Path)  ->
    "/" ++ string:join(normalize_path1(string:tokens(Path,
                "/"), []), [?SEPARATOR]).


normalize_path1([], Acc) ->
    lists:reverse(Acc);
normalize_path1([".."|Rest], Acc) ->
    Acc1 = case Acc of
        [] -> [".."|Acc];
        [T|_] when T =:= ".." -> [".."|Acc];
        [_|R] -> R
    end,
    normalize_path1(Rest, Acc1);
normalize_path1(["."|Rest], Acc) ->
    normalize_path1(Rest, Acc);
normalize_path1([Path|Rest], Acc) ->
    normalize_path1(Rest, [Path|Acc]).


%% @doc transform json rule in erlang for pattern matching
make_rule(Rule) ->
    Method = case couch_util:get_value(<<"method">>, Rule) of
        undefined -> '*';
        M -> list_to_atom(?b2l(M))
    end,
    QueryArgs = case couch_util:get_value(<<"query">>, Rule) of
        undefined -> [];
        {Args} -> Args
        end,
    FromParts  = case couch_util:get_value(<<"from">>, Rule) of
        undefined -> ['*'];
        From ->
            parse_path(From)
        end,
    ToParts  = case couch_util:get_value(<<"to">>, Rule) of
        undefined ->
            throw({error, invalid_rewrite_target});
        To ->
            parse_path(To)
        end,
    [{FromParts, Method}, ToParts, QueryArgs].

parse_path(Path) ->
    {ok, SlashRE} = re:compile(<<"\\/">>),
    path_to_list(re:split(Path, SlashRE), [], 0).

%% @doc convert a path rule (from or to) to an erlang list
%% * and path variable starting by ":" are converted
%% in erlang atom.
path_to_list([], Acc, _DotDotCount) ->
    lists:reverse(Acc);
path_to_list([<<>>|R], Acc, DotDotCount) ->
    path_to_list(R, Acc, DotDotCount);
path_to_list([<<"*">>|R], Acc, DotDotCount) ->
    path_to_list(R, [?MATCH_ALL|Acc], DotDotCount);
path_to_list([<<"..">>|R], Acc, DotDotCount) when DotDotCount == 2 ->
    case couch_config:get("httpd", "secure_rewrites", "true") of
    "false" ->
        path_to_list(R, [<<"..">>|Acc], DotDotCount+1);
    _Else ->
        ?LOG_INFO("insecure_rewrite_rule ~p blocked", [lists:reverse(Acc) ++ [<<"..">>] ++ R]),
        throw({insecure_rewrite_rule, "too many ../.. segments"})
    end;
path_to_list([<<"..">>|R], Acc, DotDotCount) ->
    path_to_list(R, [<<"..">>|Acc], DotDotCount+1);
path_to_list([P|R], Acc, DotDotCount) ->
    P1 = case P of
        <<":", Var/binary>> ->
            list_to_atom(binary_to_list(Var));
        _ -> P
    end,
    path_to_list(R, [P1|Acc], DotDotCount).

encode_query(Props) ->
    Props1 = lists:foldl(fun ({K, V}, Acc) ->
        V1 = case is_list(V) of
            true -> V;
            false when is_binary(V) ->
                V;
            false ->
                mochiweb_util:quote_plus(V)
        end,
        [{K, V1} | Acc]
    end, [], Props),
    lists:flatten(mochiweb_util:urlencode(Props1)).

to_atom(V) when is_atom(V) ->
    V;
to_atom(V) when is_binary(V) ->
    to_atom(?b2l(V));
to_atom(V) ->
    list_to_atom(V).

to_json(V) ->
    iolist_to_binary(?JSON_ENCODE(V)).
