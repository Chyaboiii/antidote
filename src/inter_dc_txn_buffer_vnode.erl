%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% This vnode is responsible for collecting transactions for a small duration.
%% Once the time runs out it passes the list of collected transactions to an
%% actor that is responsible for compacting the CCRDT operations in those transactions.
%% The buffer of transactions is then wiped clean and the timer restarted.

-module(inter_dc_txn_buffer_vnode).
-behaviour(riak_core_vnode).
-include("antidote.hrl").
-include("inter_dc_repl.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
  buffer/2,
  compact/1]).

%% VNode Functions
-export([
  init/1,
  start_vnode/1,
  handle_command/3,
  handle_coverage/4,
  handle_exit/3,
  handoff_starting/2,
  handoff_cancelled/1,
  handoff_finished/2,
  handle_handoff_command/3,
  handle_handoff_data/2,
  encode_handoff_item/2,
  is_empty/1,
  terminate/2,
  delete/1]).

%% Vnode State
-record(state, {
  partition :: partition_id(),
  buffer :: [#interdc_txn{}],
  timer :: any()
}).

%%%% API

-spec buffer(partition_id(), #interdc_txn{}) -> ok.
buffer(Partition, Txn) -> dc_utilities:call_vnode(Partition, inter_dc_txn_buffer_vnode_master, {buffer, Txn}).

%%%% VNode Callbacks

start_vnode(I) -> riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
  {ok, set_timer(#state{
    partition = Partition,
    buffer = [],
    timer = none
  })}.

handle_command({buffer, Txn}, _Sender, State = #state{buffer = Buffer}) ->
  State1 = State#state{buffer = [Txn | Buffer]},
  {reply, ok, State1};
handle_command(send, _Sender, State = #state{buffer = Buffer}) ->
  case Buffer of
    [] -> ok;
    _ ->
      Buf = lists:reverse(Buffer),
      lager:info("Sending transactions from buffer: ~p~n", [Buf]),
      spawn(fun() -> compact_and_broadcast(Buf) end)
  end,
  State1 = set_timer(State#state{buffer = []}),
  {noreply, State1}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
  {stop, not_implemented, State}.
handle_exit(_Pid, _Reason, State) ->
  {noreply, State}.
handoff_starting(_TargetNode, State) ->
  {true, State}.
handoff_cancelled(State) ->
  {ok, State}.
handoff_finished(_TargetNode, State) ->
  {ok, State}.
handle_handoff_command( _Message , _Sender, State) ->
  {noreply, State}.
handle_handoff_data(_Data, State) ->
  {reply, ok, State}.
encode_handoff_item(Key, Operation) ->
  term_to_binary({Key, Operation}).
is_empty(State) ->
  {true, State}.
delete(State) ->
  {ok, State}.
terminate(_Reason, State) ->
  _ = del_timer(State),
  ok.

%%%%%%%%%%%%%%%%%%%%%%%5

%% Cancels the send timer, if one is set.
-spec del_timer(#state{}) -> #state{}.
del_timer(State = #state{timer = none}) -> State;
del_timer(State = #state{timer = Timer}) ->
  _ = erlang:cancel_timer(Timer),
  State#state{timer = none}.

%% Sets the send timer.
-spec set_timer(#state{}) -> #state{}.
set_timer(State = #state{partition = Partition}) ->
  {ok, Ring} = riak_core_ring_manager:get_my_ring(),
  Node = riak_core_ring:index_owner(Ring, Partition),
  MyNode = node(),
  case Node of
    MyNode ->
      State1 = del_timer(State),
      State1#state{timer = riak_core_vnode:send_command_after(?BUFFER_TXN_TIMER, send)};
    _Other -> State
  end.

-spec broadcast([#interdc_txn{}]) -> ok.
broadcast(Buffer) ->
  lager:info("Broadcasting: ~p~n", [Buffer]),
  lists:foreach(fun(Txn) -> inter_dc_pub:broadcast(Txn) end, Buffer).

-spec compact_and_broadcast([#interdc_txn{}]) -> ok.
compact_and_broadcast(Buffer) ->
  broadcast(compact(Buffer)).

get_txid(Txn) ->
  Record = hd(Txn#interdc_txn.log_records),
  Record#log_record.log_operation#log_operation.tx_id.

%% TODO: @gmcabrita Test this function.
-spec compact([#interdc_txn{}]) -> [#interdc_txn{}].
compact([]) -> [];
compact(Buffer) ->
  % map of {Key, Bucket} -> [#log_record{}] for the CCRDT update operations,
  % list of #log_record{} for the non-CCRDT update operations (can't be compacted),
  % list of transactions (with update ops removed)
  TxnId = get_txid(lists:last(Buffer)),
  {CCRDTUpdateOps, ReversedOtherUpdateOps, ReversedTxns} =
    lists:foldl(fun(Txn = #interdc_txn{log_records = Logs}, {CCRDTOps, Ops, Txns}) ->
      {CCRDTUpdates, Updates, Other} = split_transaction_records(Logs, {CCRDTOps, Ops}, TxnId),
      CleanedTxn = Txn#interdc_txn{log_records = lists:reverse(Other)},
      {CCRDTUpdates, Updates, [CleanedTxn | Txns]}
    end, {#{}, [], []}, Buffer),
  case maps:size(CCRDTUpdateOps) == 0 of
    % there are no CCRDTs in the transactions, return the original transactions
    true -> Buffer;
    false ->
      CompactedMapping = maps:map(fun(_, LogRecords) -> compact_log_records(lists:reverse(LogRecords)) end, CCRDTUpdateOps),
      Txn = hd(ReversedTxns),
      FstTxn = hd(Buffer),
      PrevLogOpId = FstTxn#interdc_txn.prev_log_opid,
      Records = Txn#interdc_txn.log_records,
      Ops = lists:flatten(maps:values(CompactedMapping)),
      %% Reverse to get the correct ordering. TODO: @gmcabrita is this actually needed?
      OtherUpdateOps = lists:reverse(ReversedOtherUpdateOps),
      [Txn#interdc_txn{log_records = OtherUpdateOps ++ Ops ++ Records, prev_log_opid = PrevLogOpId}]
  end.

-spec split_transaction_records([#log_record{}], {#{}, [#log_record{}]}, txid()) -> {#{}, [#log_record{}], #log_record{}}.
split_transaction_records(Logs, {CCRDTOps, Ops}, TxId) ->
  lists:foldl(fun(Log, Acc) -> place_txn_record(Log, Acc, TxId) end, {CCRDTOps, Ops, []}, Logs).

-spec place_txn_record(#log_record{}, {#{}, [#log_record{}], [#log_record{}]}, txid()) -> {#{}, [#log_record{}], [#log_record{}]}.
place_txn_record(
  LogRecordArg = #log_record{
                log_operation = #log_operation{
                                  op_type = OpType,
                                  log_payload = LogPayload}}, {CCRDTOpsMap, UpdateOps, OtherOps}, TxId) ->
  %% update operation to a specific txid
  LogOp = LogRecordArg#log_record.log_operation,
  LogRecord = LogRecordArg#log_record{log_operation = LogOp#log_operation{tx_id = TxId}},
  case OpType of
    update ->
      {Key, Bucket, Type, _Op} = destructure_update_payload(LogPayload),
      case antidote_ccrdt:is_type(Type) of
        true ->
          K = {Key, Bucket},
          NC = case maps:is_key(K, CCRDTOpsMap) of
            true ->
              Current = maps:get(K, CCRDTOpsMap),
              maps:put(K, [LogRecord | Current], CCRDTOpsMap);
            false -> maps:put(K, [LogRecord], CCRDTOpsMap)
          end,
          {NC, UpdateOps, OtherOps};
        false -> {CCRDTOpsMap, [LogRecord | UpdateOps], OtherOps}
      end;
    _ -> {CCRDTOpsMap, UpdateOps, [LogRecord | OtherOps]}
  end.

-spec get_op(#log_record{}) -> op().
get_op(#log_record{log_operation = #log_operation{log_payload = #update_log_payload{op = Op}}}) ->
  Op.

-spec get_type(#log_record{}) -> type().
get_type(#log_record{log_operation = #log_operation{log_payload = #update_log_payload{type = Type}}}) ->
  Type.

-spec replace_op(#log_record{}, op()) -> #log_record{}.
replace_op(LogRecord, Op) ->
  LogOp = LogRecord#log_record.log_operation,
  LogPayload = LogOp#log_operation.log_payload,
  LogRecord#log_record{log_operation = LogOp#log_operation{log_payload = LogPayload#update_log_payload{op = Op}}}.

-spec destructure_update_payload(#update_log_payload{}) -> {key(), bucket(), type(), op()}.
destructure_update_payload(#update_log_payload{key = Key, bucket = Bucket, type = Type, op = Op}) ->
  {Key, Bucket, Type, Op}.

-spec compact_log_records([#log_record{}]) -> [#log_record{}].
compact_log_records(LogRecords) ->
  lists:reverse(lists:foldl(fun(LogRecord, LogAcc) ->
    log(LogAcc, LogRecord)
  end, [], LogRecords)).

-spec log([#log_record{}], #log_record{}) -> [#log_record{}].
log(LogAcc, LogRecord) ->
  case log_(LogAcc, LogRecord) of
    {ok, Logs} -> Logs;
    {err, Logs} -> [LogRecord | Logs]
  end.

-spec log_([#log_record{}], #log_record{}) -> {ok | err, [#log_record{}]}.
log_([], _) -> {err, []};
log_([LogRecord2 | Rest], LogRecord1) ->
  Type = get_type(LogRecord1),
  Op1 = get_op(LogRecord1),
  Op2 = get_op(LogRecord2),
  case Type:can_compact(Op2, Op1) of
    true ->
      case Type:compact_ops(Op2, Op1) of
        {noop} -> {ok, Rest};
        NewOp ->
          NewRecord = replace_op(LogRecord1, NewOp),
          {ok, [NewRecord | Rest]}
      end;
    false ->
      case log_(Rest, LogRecord1) of
        {ok, List} -> {ok, [LogRecord2 | List]};
        {err, _} -> {err, [LogRecord2 | Rest]}
      end
  end.

%%% Tests

-ifdef(TEST).

inter_dc_txn_from_ops(Ops, PrevLogOpId, N, TxId, CommitTime, SnapshotTime) ->
  {Records, Number} = lists:foldl(fun({Key, Bucket, Type, Op}, {List, Number}) ->
    Record = #log_record{
      version = 0,
      op_number = Number,
      bucket_op_number = Number,
      log_operation = #log_operation{
        tx_id = TxId,
        op_type = update,
        log_payload = #update_log_payload{
          key = Key,
          bucket = Bucket,
          type = Type,
          op = Op
        }
      }
    },
    {[Record | List], Number + 1}
  end, {[], N}, Ops),
  {RecordsCCRDT, RecordsOther, _} = split_transaction_records(lists:reverse(Records), {#{}, []}, TxId),
  Prepare = #log_record{version = 0, op_number = Number, bucket_op_number = Number, log_operation = #log_operation{tx_id = TxId, op_type = prepare, log_payload = #prepare_log_payload{prepare_time = CommitTime - 1}}},
  Commit = #log_record{version = 0, op_number = Number + 1, bucket_op_number = Number + 1, log_operation = #log_operation{tx_id = TxId, op_type = commit, log_payload = #commit_log_payload{commit_time = CommitTime, snapshot_time = SnapshotTime}}},
  LogRecords = lists:reverse(RecordsOther) ++ lists:flatten(lists:map(fun lists:reverse/1, maps:values(RecordsCCRDT))) ++ [Prepare, Commit],
  #interdc_txn{
    dcid = replica1,
    partition = 1,
    prev_log_opid = PrevLogOpId,
    snapshot = SnapshotTime,
    timestamp = CommitTime,
    log_records = LogRecords
  }.

empty_txns_test() ->
  ?assertEqual(compact([]), []).

no_ccrdts_test() ->
  Buffer1 = [
    inter_dc_txn_from_ops([{key, bucket, non_ccrdt, some_operation}],
                          0,
                          1,
                          1,
                          200,
                          50)
  ],
  ?assertEqual(compact(Buffer1), Buffer1),
  Buffer2 = Buffer1 ++ [inter_dc_txn_from_ops([{key, bucket, non_ccrdt, some_operation}], 1, 2, 2, 300, 250)],
  ?assertEqual(compact(Buffer2), Buffer2).

different_ccrdt_types_test() ->
  TopkD = antidote_ccrdt_topk_with_deletes,
  Topk = antidote_ccrdt_topk,
  Average = antidote_ccrdt_average,
  Buffer = [
    inter_dc_txn_from_ops([{topkd, bucket, TopkD, {add, {0, 5, {foo, 1}}}},
                           {topk, bucket, Topk, {add, {100, 5}}},
                           {average, bucket, Average, {add, {10, 1}}},
                           {topkd, bucket, TopkD, {del, {0, #{foo => {foo, 1}}}}},
                           {topk, bucket, Topk, {add, {100, 42}}},
                           {average, bucket, Average, {add, {100, 2}}}],
                          0,
                          1,
                          1,
                          200,
                          50)
  ],
  Expected = [
    inter_dc_txn_from_ops([{topkd, bucket, TopkD, {del, {0, #{foo => {foo, 1}}}}},
                           {topk, bucket, Topk, {add, {100, 42}}},
                           {average, bucket, Average, {add, {110, 3}}}],
                          0,
                          4,
                          1,
                          200,
                          50)
  ],
  ?assertEqual(compact(Buffer), Expected).

txn_ccrdt_mixed_with_crdt_test() ->
  CCRDT = antidote_ccrdt_topk_with_deletes,
  Buffer = [
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {add, {0, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {del, {0, #{foo => {foo, 1}}}}}],
                          0,
                          1,
                          1,
                          100,
                          50),
    inter_dc_txn_from_ops([{a, bucket, not_a_ccrdt, {add, {100, 5, {foo, 1}}}},
                           {a, bucket, not_a_ccrdt, {add, {77, 5, {foo, 1}}}}],
                          2,
                          3,
                          2,
                          200,
                          150)
  ],
  Expected = [
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {del, {0, #{foo => {foo, 1}}}}},
                           {a, bucket, not_a_ccrdt, {add, {100, 5, {foo, 1}}}},
                           {a, bucket, not_a_ccrdt, {add, {77, 5, {foo, 1}}}}],
                          0,
                          2,
                          2,
                          200,
                          150)
  ],
  ?assertEqual(compact(Buffer), Expected).

compactable_txn_test() ->
  CCRDT = antidote_ccrdt_topk_with_deletes,
  Buffer = [
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {add, {0, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {del, {0, #{foo => {foo, 1}}}}}],
                          0,
                          1,
                          1,
                          150,
                          200)
  ],
  Expected = [
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {del, {0, #{foo => {foo, 1}}}}}],
                          0,
                          2,
                          1,
                          150,
                          200)
  ],
  ?assertEqual(compact(Buffer), Expected).

two_ccrdt_txn_not_compactable_test() ->
  CCRDT = antidote_ccrdt_topk_with_deletes,
  Buffer = [
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {add, {0, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {1, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {2, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {3, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {4, 5, {foo, 1}}}}],
                          0,
                          1,
                          1,
                          100,
                          50),
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {add, {5, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {6, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {7, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {8, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {9, 5, {foo, 1}}}}],
                          5,
                          6,
                          2,
                          200,
                          150)
  ],
  Expected = [
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {add, {0, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {1, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {2, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {3, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {4, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {5, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {6, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {7, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {8, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {9, 5, {foo, 1}}}}],
                          0,
                          1,
                          2,
                          200,
                          150)
  ],
  ?assertEqual(compact(Buffer), Expected).

single_ccrdt_txn_not_compactable_test() ->
  CCRDT = antidote_ccrdt_topk_with_deletes,
  Buffer = [
    inter_dc_txn_from_ops([{top, bucket, CCRDT, {add, {0, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {1, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {2, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {3, 5, {foo, 1}}}},
                           {top, bucket, CCRDT, {add, {4, 5, {foo, 1}}}}],
                          0,
                          1,
                          1,
                          100,
                          50)
  ],
  ?assertEqual(compact(Buffer), Buffer).

-endif.