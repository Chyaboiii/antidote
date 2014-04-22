-module(logging_vnode).

-behaviour(riak_core_vnode).

-include("floppy.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_vnode/1,
         dread/2,
         dupdate/4,
         repair/2,
         read/2,
         append/3,
         prune/3]).

-export([init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-ignore_xref([start_vnode/1]).

-record(state, {partition, log, objects}).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

read(Node, Key) ->
    riak_core_vnode_master:sync_command(Node, {read, Key}, ?LOGGINGMASTER).

dread(Preflist, Key) ->
    riak_core_vnode_master:command(Preflist, {read, Key}, {fsm, undefined, self()},?LOGGINGMASTER).

dupdate(Preflist, Key, Op, LClock) ->
    riak_core_vnode_master:command(Preflist, {append, Key, Op, LClock},{fsm, undefined, self()}, ?LOGGINGMASTER).

repair(Preflist, Ops) ->
    riak_core_vnode_master:command(Preflist, {repair, Ops},{fsm, undefined, self()}, ?LOGGINGMASTER).

append(Node, Key, Op) ->
    riak_core_vnode_master:sync_command(Node, {append, Key, Op}, ?LOGGINGMASTER).

prune(Node, Key, Until) ->
    riak_core_vnode_master:sync_command(Node, {prune, Key, Until}, ?LOGGINGMASTER).

init([Partition]) ->
    LogFile = string:concat(integer_to_list(Partition), "log"),
    LogPath = filename:join(
            app_helper:get_env(riak_core, platform_data_dir), LogFile),
    case dets:open_file(LogFile, [{file, LogPath}, {type, bag}]) of
        {ok, Log} ->
            {ok, #state{partition=Partition, log=Log}};
        {error, Reason} ->
            {error, Reason}
    end.

handle_command({read, Key}, _Sender, #state{partition=Partition, log=Log}=State) ->
    case dets:lookup(Log, Key) of
        [] ->
            {reply, {{Partition, node()}, []}, State};
        [H|T] ->
            {reply, {{Partition, node()}, [H|T]}, State};
        {error, Reason}->
            {reply, {error, Reason}, State}
    end;

handle_command({repair, Ops}, _Sender, #state{log=Log}=State) ->
    dets:insert(Log, Ops),
    {reply, State};

handle_command({append, Key, Payload, OpId}, _Sender,
               #state{partition=Partition, log=Log}=State) ->
    dets:insert(Log, {Key, #operation{opNumber=OpId, payload=Payload}}),
    {reply, {{Partition,node()}, OpId}, State};

handle_command({prune, _, _}, _Sender, State) ->
    {reply, {ok, State#state.partition}, State};

handle_command(Message, _Sender, State) ->
    ?PRINT({unhandled_command_logging, Message}),
    {noreply, State}.

handle_handoff_command(_Message, _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(_ObjectName, _ObjectValue) ->
    <<>>.

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
