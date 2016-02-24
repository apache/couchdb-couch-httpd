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

-module(couch_httpd_util).

-export([
    fun_from_spec/2
]).

% SpecStr is a string like "{my_module, my_fun}"
%  or "{my_module, my_fun, <<"my_arg">>}"
fun_from_spec(SpecStr, 1) ->
    case couch_util:parse_term(SpecStr) of
    {ok, {Mod, Fun, SpecArg}} ->
        fun(Arg) -> Mod:Fun(Arg, SpecArg) end;
    {ok, {Mod, Fun}} ->
        fun(Arg) -> Mod:Fun(Arg) end
    end;

fun_from_spec(SpecStr, 2) ->
    case couch_util:parse_term(SpecStr) of
    {ok, {Mod, Fun, SpecArg}} ->
        fun(Arg1, Arg2) -> Mod:Fun(Arg1, Arg2, SpecArg) end;
    {ok, {Mod, Fun}} ->
        fun(Arg1, Arg2) -> Mod:Fun(Arg1, Arg2) end
    end;

fun_from_spec(SpecStr, 3) ->
    case couch_util:parse_term(SpecStr) of
    {ok, {Mod, Fun, SpecArg}} ->
        fun(Arg1, Arg2, Arg3) -> Mod:Fun(Arg1, Arg2, Arg3, SpecArg) end;
    {ok, {Mod, Fun}} ->
        fun(Arg1, Arg2, Arg3) -> Mod:Fun(Arg1, Arg2, Arg3) end
    end.
