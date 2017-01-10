%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
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

%% InterDC publisher - holds a ZeroMQ PUB socket and makes it available for Antidote processes.
%% This vnode is used to publish interDC transactions.

-module(inter_dc_pub).
-behaviour(gen_server).
-include("antidote.hrl").
-include("inter_dc_repl.hrl").

%% API
-export([
  broadcast/1,
  broadcast_tuple/1,
  get_address/0,
  get_address_list/0]).

%% Server methods
-export([
  init/1,
  start_link/0,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

%% State
-record(state, {socket}). %% socket :: erlzmq_socket()

%%%% API --------------------------------------------------------------------+

-spec get_address() -> socket_address().
get_address() ->
  %% TODO check if we do not return a link-local address
  {ok, DirName} = file:get_cwd(),
  ConfigFileDir = DirName ++ "/../../../../config/node-address.config", %% /config
  lager:info("Reading public accessible IP from :~p~n",[ConfigFileDir]),
  {ok, NodeAddressProps} = file:consult(ConfigFileDir),
  Ip = proplists:get_value(public_ip, NodeAddressProps),
  Port = application:get_env(antidote, pubsub_port, ?DEFAULT_PUBSUB_PORT),
  {Ip, Port}.

-spec get_address_list() -> [socket_address()].
get_address_list() ->
    {ok, DirName} = file:get_cwd(),
    ConfigFileDir = DirName ++ "/../../../../config/node-address.config", %% /config
    lager:info("Reading public accessible IP from :~p~n",[ConfigFileDir]),
    {ok, NodeAddressProps} = file:consult(ConfigFileDir),
    Ip = proplists:get_value(public_ip, NodeAddressProps),
    {Fst,Snd,Thd,Fth} = Ip,
    {ok,IpList} = inet:getif(),
    List = [{Ip, {Fst,Snd,Thd,255}, {255,255,255,0}} | tl(IpList)],
    Port = application:get_env(antidote, pubsub_port, ?DEFAULT_PUBSUB_PORT),
    [{Ip1, Port} || {Ip1, _, _} <- List, Ip1 /= {127, 0, 0, 1}].

-spec broadcast_tuple({#interdc_txn{}, #interdc_txn{}}) -> ok.
broadcast_tuple({TxnShort, TxnFull}) ->
  DCs = case stable_meta_data_server:read_meta_data(dc_list) of
    {ok, List} -> List;
    _ -> []
  end,

  % Shuffle list of DCs
  ShuffledDCs = [X || {_,X} <- lists:sort([{rand:uniform(), N} || N <- DCs])],
  {DCsFull, DCsShort} = case ShuffledDCs of
    [] -> {[], []};
    _ -> lists:split(?CCRDT_REPLICATION_FACTOR - 1, ShuffledDCs)
  end,

  % Broadcast Full Txn
  lists:foreach(fun(DcId) ->
    case catch gen_server:call(?MODULE, {publish, inter_dc_txn:to_bin(TxnFull, DcId)}) of
      {'EXIT', _Reason} -> lager:warning("Failed to broadcast a transaction to ~p.", [DcId]); %% this can happen if a node is shutting down.
      Normal ->
        %lager:info("Successfully sent full txn to DC: ~p.", [DcId]),
        Normal
    end
  end, DCsFull),

  % Broadcast Short Txn
  lists:foreach(fun(DcId) ->
    case catch gen_server:call(?MODULE, {publish, inter_dc_txn:to_bin(TxnShort, DcId)}) of
      {'EXIT', _Reason} -> lager:warning("Failed to broadcast a transaction to ~p.", [DcId]); %% this can happen if a node is shutting down.
      Normal ->
        %lager:info("Successfully sent short txn to DC: ~p.", [DcId]),
        Normal
    end
  end, DCsShort).

-spec broadcast(#interdc_txn{}) -> ok.
broadcast(Txn) ->
  % Grab list of remote DCs
  DCs = case stable_meta_data_server:read_meta_data(dc_list) of
    {ok, List} -> List;
    _ -> []
  end,

  case DCs of
    [] -> ok;
    _ ->
      % For each remote DC send the transaction
      lists:foreach(fun(DcId) ->
        case catch gen_server:call(?MODULE, {publish, inter_dc_txn:to_bin(Txn, DcId)}) of
          {'EXIT', _Reason} -> lager:warning("Failed to broadcast a transaction to ~p.", [DcId]); %% this can happen if a node is shutting down.
          Normal -> Normal
        end
      end, DCs)
  end.

%%%% Server methods ---------------------------------------------------------+

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  {_, Port} = get_address(),
  Socket = zmq_utils:create_bind_socket(pub, false, Port),
  lager:info("Publisher started on port ~p", [Port]),
  {ok, #state{socket = Socket}}.

handle_call({publish, Message}, _From, State) -> {reply, erlzmq:send(State#state.socket, Message), State}.

terminate(_Reason, State) -> erlzmq:close(State#state.socket).
handle_cast(_Request, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
