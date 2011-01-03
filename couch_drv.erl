-module(couch_drv).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-export([start_link/0]).

-include("couch_db.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    LibDir =
    case couch_config:get("couchdb", "util_driver_dir", null) of
    null ->
        filename:join(couch_util:priv_dir(), "lib");
    LibDir0 -> LibDir0
    end,
    

    case erl_ddll:load(LibDir, "couch_icu_driver") of
    ok ->
        {ok, nil};
    {error, already_loaded} ->
        ?LOG_INFO("~p reloading couch_erl_driver", [?MODULE]),
        ok = erl_ddll:reload(LibDir, "couch_erl_driver"),
        {ok, nil};
    {error, Error} ->
        {stop, erl_ddll:format_error(Error)}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
