-module(clocksi_interactive_tx_coord_fsm).

-behavior(gen_fsm).

-include("clocksi.hrl").

%% API
-export([start_link/2, start_link/1]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([execute_op/2, prepare/2, read/2,
         receive_prepared/2, committing/2, receive_committed/2,  abort/2]).

%%%===================================================================
%%% API
%%%===================================================================

start_link(From, ClientClock) ->
    gen_fsm:start_link(?MODULE, [From, ClientClock], []).

start_link(From) ->
    gen_fsm:start_link(?MODULE, [From, ignore], []).

%%%===================================================================
%%% States
%%%===================================================================

%% @doc Initialize the state.
init([From, ClientClock]) ->
    Clocks = ?CLOCKS_IMPLEMENTATION,
    SD0 = #coord_state{clocks=Clocks,
                       client_clock=ClientClock},
    {SnapshotTime, SD1} = Clocks:get_snapshot_time(SD0),
    UId = clocksi:mk_reqid(),
    TxId = {UId, self()},
    From ! {ok, TxId},
    {ok, execute_op, SD1#coord_state{tx_id=TxId,
                                     prepare_time=Clocks:init_clock(),
                                     snapshot_time=SnapshotTime}}.

%% @doc Contact the leader computed in the prepare state for it to execute the
%%      operation, wait for it to finish (synchronous) and go to the prepareOP
%%       to execute the next operation.
execute_op({OpType, Args, Sender},
           SD0=#coord_state{tx_id=_TxId,
                            snapshot_time=SnapshotTime,
                            from=_From,
                            updated_partitions=UpdatedPartitions0,
                            partitions_buffer_keys=PartitionsBufferKeys0,
                            partitions_buffer_values=PartitionsBufferValues0,
                            reads_buffer=ReadsBuffer0,
                            updates_buffer=UpdatesBuffer0}) ->
    case OpType of
        commit ->
            {next_state, prepare, SD0#coord_state{from=Sender}, 0};
        read ->
            Key=Args,
            IndexNode = clocksi:get_responsible(Key),
            case IndexNode of
                [] ->
                    {reply, {error, partition_not_reachable}, abort, SD0, 0};    
                _ ->
                    case dict:find(Key, UpdatesBuffer0) of
                        {ok, Value} ->
                            Sender ! {ok, Value},
                            {next_state, execute_op, SD0};
                            %{reply, {ok, Value}, execute_op, SD0};
                        error ->
                            case dict:find(Key, ReadsBuffer0) of
                                {ok, Value} ->
                                    Sender ! {ok, Value},
                                    {next_state, execute_op, SD0};
                                    %{reply, {ok, Value}, execute_op, SD0};
                                error ->
                                    clocksi_vnode:read_data_item(IndexNode, Key, SnapshotTime),
                                    {next_state, read, SD0#coord_state{from=Sender, key=Key}}
                            end
                    end
            end;
        update ->
            {Key, Value}=Args,
            IndexNode = clocksi:get_responsible(Key),
            case IndexNode of
                [] ->
                    {reply, {error, partition_not_reachable}, abort, SD0, 0};    
                _ ->
                    UpdatesBuffer = dict:store(Key, Value, UpdatesBuffer0),
                    case dict:find(hd(IndexNode), PartitionsBufferKeys0) of
                        {ok, Dict0} ->
                            Dict1 = dict:store(Key, Value, Dict0);
                        error ->
                            Dict0 = dict:new(),
                            Dict1 = dict:store(Key, Value, Dict0)
                    end,
                    PartitionsBufferValues = dict:store(hd(IndexNode), Dict1, PartitionsBufferValues0),  
                    PartitionsBufferKeys = dict:append(hd(IndexNode), Key, PartitionsBufferKeys0),
                    case lists:member(hd(IndexNode), UpdatedPartitions0) of
                        false ->
                            UpdatedPartitions = UpdatedPartitions0 ++ IndexNode,
                            Sender ! ok,
                            %{reply, ok, execute_op, SD0#coord_state{updated_partitions=UpdatedPartitions,
                            {next_state, execute_op, SD0#coord_state{updated_partitions=UpdatedPartitions,
                                                                    updates_buffer=UpdatesBuffer,
                                                                    partitions_buffer_keys=PartitionsBufferKeys,
                                                                    partitions_buffer_values=PartitionsBufferValues}};
                        true->
                            Sender ! ok,
                            %{reply, ok, execute_op, SD0#coord_state{updates_buffer=UpdatesBuffer,
                            {next_state, execute_op, SD0#coord_state{updates_buffer=UpdatesBuffer,
                                                                    partitions_buffer_keys=PartitionsBufferKeys,
                                                                    partitions_buffer_values=PartitionsBufferValues}}
                    end
            end
    end.

read({ok, Value}, SD0=#coord_state{from=From,
                               reads_buffer=ReadsBuffer0,
                               key=Key}) ->
    From ! {ok, Value},
    %gen_fsm:reply(From, {ok, Value}),
    ReadsBuffer = dict:store(Key, Value, ReadsBuffer0),
    {next_state, execute_op, SD0#coord_state{reads_buffer=ReadsBuffer}};

read({error, Reason}, SD0=#coord_state{from=From}) ->
    From ! {error, Reason},
    %gen_fsm:reply(From, {error, Reason}),
    {stop, normal, SD0}.

%% @doc a message from a client wanting to start committing the tx.
%%      this state sends a prepare message to all updated partitions and goes
%%      to the "receive_prepared"state.
prepare(timeout, SD0=#coord_state{snapshot_time=SnapshotTime,
                                  tx_id=TxId,
                                  updated_partitions=UpdatedPartitions, 
                                  from=From,
                                  updates_buffer=UpdatesBuffer,
                                  partitions_buffer_keys=PartitionsBufferKeys}) ->
    case length(UpdatedPartitions) of
        0 ->
            
            SD = reply_to_client(SD0#coord_state{state=committed, commit_time=SnapshotTime}),
            {stop, normal, SD};
        1 ->
            clocksi_vnode:local_commit(hd(UpdatedPartitions), dict:to_list(UpdatesBuffer), TxId, SnapshotTime, From),
            {stop, normal, SD0#coord_state{state=committed}};
        _ ->
            lists:foreach(fun(IndexNode) ->
                            Keys = dict:fetch(IndexNode, PartitionsBufferKeys),
                            clocksi_vnode:prepare([IndexNode], Keys, TxId, SnapshotTime)
                          end, UpdatedPartitions),
            NumAck=length(UpdatedPartitions),
            {next_state, receive_prepared, SD0#coord_state{num_ack=NumAck, state=preparing}}
    end.

%% @doc in this state, the fsm waits for prepare_time from each updated
%%      partitions in order to compute the final tx timestamp (the maximum
%%      of the received prepare_time).
receive_prepared({prepared, ReceivedPrepareTime}, SD0=#coord_state{num_ack= NumAck,
                                                                   clocks=Clocks,
                                                                   prepare_time=PrepareTime}) ->
    MaxPrepareTime = Clocks:max_time(PrepareTime, ReceivedPrepareTime),
    case NumAck of
        1 ->
            {next_state, committing, SD0#coord_state{prepare_time=MaxPrepareTime,commit_time=MaxPrepareTime, state=committing}, 0};
        _ ->
            {next_state, receive_prepared, SD0#coord_state{num_ack= NumAck-1, prepare_time=MaxPrepareTime}}
    end;

receive_prepared(abort, SD0) ->
    {next_state, abort, SD0, 0}.

%% @doc after receiving all prepare_times, send the commit message to all
%%       updated partitions, and go to the "receive_committed" state.
committing(timeout, SD0=#coord_state{tx_id=TxId,
                                     updated_partitions=UpdatedPartitions,
                                     partitions_buffer_values=PartitionsBufferValues,
                                     commit_time=CommitTime}) ->
    NumAck=length(UpdatedPartitions),
    lists:foreach(fun(IndexNode) ->
                    Updates = dict:fetch(IndexNode, PartitionsBufferValues),
                    clocksi_vnode:commit([IndexNode], dict:to_list(Updates), TxId, CommitTime)
                  end, UpdatedPartitions),
    SD = reply_to_client(SD0#coord_state{state=committed}),
    {next_state, receive_committed, SD#coord_state{num_ack=NumAck}}.

%% @doc the fsm waits for acks indicating that each partition has successfully
%%	committed the tx and finishes operation.
%%      Should we retry sending the committed message if we don't receive a
%%      reply from every partition?
%%      What delivery guarantees does sending messages provide?
receive_committed(committed, SD0=#coord_state{num_ack=NumAck}) ->
    case NumAck of
        1 ->
            {stop, normal, SD0#coord_state{state=committed}};
        _ ->
            {next_state, receive_committed, SD0#coord_state{num_ack=NumAck-1}}
    end.

%% @doc when an error occurs or an updated partition 
%% does not pass the certification check, the transaction aborts.
abort(timeout, SD0=#coord_state{tx_id=TxId,
                                updated_partitions=UpdatedPartitions}) ->
    clocksi_vnode:abort(UpdatedPartitions, TxId),
    SD = reply_to_client(SD0#coord_state{state=aborted}),
    {stop, normal, SD};

abort(abort, SD0=#coord_state{tx_id=TxId,
                              updated_partitions=UpdatedPartitions}) ->
    clocksi_vnode:abort(UpdatedPartitions, TxId),
    SD = reply_to_client(SD0#coord_state{state=aborted}),
    {stop, normal, SD}.

%% =============================================================================

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%% @doc when the transaction has committed or aborted,
%%       a reply is sent to the client that started the transaction.
reply_to_client(SD0=#coord_state{tx_id=TxId, clocks=Clocks, state=TxState, from=From}) ->
    case From of
        undefined ->
            SD0;
        _ ->
            Reply = case TxState of
                        committed ->
                            {ClientClock, SD} = Clocks:get_commit_client_clock(SD0),
                            {ok, {TxId, ClientClock}};
                        aborted->
                            SD = SD0,
                            {aborted, TxId};
                        Reason->
                            SD = SD0,
                            {error, TxId, Reason}
                    end,
            From ! Reply,
            SD
            %gen_fsm:reply(From, Reply)
    end.
