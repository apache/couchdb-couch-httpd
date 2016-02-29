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

-module(couch_httpd_config_listener).
-vsn(3).
-behaviour(config_listener).

% public interface
-export([subscribe/2]).

% config_listener callback
-export([handle_config_change/5, handle_config_terminate/3]).

subscribe(Stack, Settings) ->
    io:format(user, "Listen for changes: ~p", [{Stack, get_config(Settings)}]),
    ok = config:listen_for_changes(?MODULE, {Stack, get_config(Settings)}),
    ok.

handle_config_change(Section, Key, Value, _, {Stack, Settings}) ->
    Id = {Section, Key},
    case couch_util:get_value(Id, Settings, not_found) of
        not_found -> {ok, {Stack, Settings}};
        Value -> {ok, {Stack, Settings}};
        _ ->
            Stack:stop(),
            {ok, {Stack, lists:keyreplace(Id, 1, Settings, {Id, Value})}}
    end.

handle_config_terminate(_, stop, _) -> ok;
handle_config_terminate(_Server, _Reason, State) ->
    spawn(fun() ->
        timer:sleep(5000),
        config:listen_for_changes(?MODULE, State)
    end).

% private

get_config(Settings) ->
    [{Id, config:get(Section, Key)} || {Section, Key} = Id <- Settings].
