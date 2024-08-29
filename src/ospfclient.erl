-module(ospfclient).

-feature(maybe_expr, enable).

-export([
    connect/1, connect/2,
    close/1,
    sync_lsdb/1,
    sync_nsm/1,
    sync_ism/1,
    sync_router_id/1,
    sync_reachable/1
]).

-export([nsm_name/1, msg_errname/1, ism_name/1]).

-export([loop/2, async_loop/3]).

-include_lib("stdlib/include/assert.hrl").

-include("ospfclient.hrl").

-define(OSPF_API_SYNC_PORT, 2607).
-define(OSPF_API_VERSION, 1).

-define(ASYNCPORT, 4000).

-define(APIMSGHDR, 8).

-define(RETRY_CONNECT_TIMEOUT, 3000).

% ------------------------
% Messages to OSPF daemon.
% ------------------------

-define(MSG_REGISTER_OPAQUETYPE, 1).
-define(MSG_UNREGISTER_OPAQUETYPE, 2).
-define(MSG_REGISTER_EVENT, 3).
-define(MSG_SYNC_LSDB, 4).
-define(MSG_ORIGINATE_REQUEST, 5).
-define(MSG_DELETE_REQUEST, 6).
-define(MSG_SYNC_REACHABLE, 7).
-define(MSG_SYNC_ISM, 8).
-define(MSG_SYNC_NSM, 9).
-define(MSG_SYNC_ROUTER_ID, 19).

% --------------------------
% Messages from OSPF daemon.
% --------------------------

-define(MSG_REPLY, 10).
-define(MSG_READY_NOTIFY, 11).
-define(MSG_LSA_UPDATE_NOTIFY, 12).
-define(MSG_LSA_DELETE_NOTIFY, 13).
-define(MSG_NEW_IF, 14).
-define(MSG_DEL_IF, 15).
-define(MSG_ISM_CHANGE, 16).
-define(MSG_NSM_CHANGE, 17).
-define(MSG_REACHABLE_CHANGE, 18).
-define(MSG_ROUTER_ID_CHANGE, 20).

% --------------------------
% OSPF API error codes.
% --------------------------

-define(OSPF_API_OK, 0).
-define(OSPF_API_NOSUCHINTERFACE, -1).
-define(OSPF_API_NOSUCHAREA, -2).
-define(OSPF_API_NOSUCHLSA, -3).
-define(OSPF_API_ILLEGALLSATYPE, -4).
-define(OSPF_API_OPAQUETYPEINUSE, -5).
-define(OSPF_API_OPAQUETYPENOTREGISTERED, -6).
-define(OSPF_API_NOTREADY, -7).
-define(OSPF_API_NOMEMORY, -8).
-define(OSPF_API_ERROR, -9).
-define(OSPF_API_UNDEF, -10).

% ------------------------------
% Interface State Machine States
% ------------------------------

-define(ISM_DEPENDUPON, 0).
-define(ISM_DOWN, 1).
-define(ISM_LOOPBACK, 2).
-define(ISM_WAITING, 3).
-define(ISM_POINTTOPOINT, 4).
-define(ISM_DROTHER, 5).
-define(ISM_BACKUP, 6).
-define(ISM_DR, 7).

% -----------------------------
% Neighbor State Machine States
% -----------------------------

-define(NSM_DEPENDUPON, 0).
-define(NSM_DELETED, 1).
-define(NSM_DOWN, 2).
-define(NSM_ATTEMPT, 3).
-define(NSM_INIT, 4).
-define(NSM_TWOWAY, 5).
-define(NSM_EXSTART, 6).
-define(NSM_EXCHANGE, 7).
-define(NSM_LOADING, 8).
-define(NSM_FULL, 9).

-type async_msg() ::
    'MSG_READY_NOTIFY'
    | 'MSG_LSA_UPDATE_NOTIFY'
    | 'MSG_LSA_DELETE_NOTIFY'
    | 'MSG_NEW_IF'
    | 'MSG_DEL_IF'
    | 'MSG_ISM_CHANGE'
    | 'MSG_NSM_CHANGE'
    | 'MSG_REACHABLE_CHANGE'
    | 'MSG_ROUTER_ID_CHANGE'.

-type async_handler() :: fun((string(), term(), any()) -> ok).

-type handlers() :: #{async_msg() => async_handler()}.

-export_type([async_msg/0, async_handler/0, handlers/0]).

-record(ospfclient, {
    host :: socket:in_addr(),
    port = ?ASYNCPORT :: non_neg_integer(),
    fd_sync = undefined :: undefined | socket:socket(),
    fd_async = undefined :: undefined | socket:socket(),
    seqnr = 0 :: non_neg_integer(),
    async_pid = undefined :: undefined | pid(),
    async_callbacks = #{} :: map(),
    async_callback_data = undefined :: any()
}).

-record(apimsghdr, {version, msgtype, msglen, msgseq}).

-record(msg, {hdr = #apimsghdr{} :: #apimsghdr{}, body}).

connect(Host) ->
    connect(Host, []).

connect(Host, Opts) when is_tuple(Host), is_list(Opts) ->
    Self = self(),
    Pid = spawn_link(fun() -> init(Host, Opts, Self) end),
    recv(Pid).

close(Handle) when is_pid(Handle) ->
    send(Handle, close).

sync_lsdb(Handle) when is_pid(Handle) ->
    LSAFilter = #lsa_filter_type{
        % all LSAs
        typemask = 16#FFFF,
        origin = ?ANY_ORIGIN,
        % all Areas
        num_areas = 0
    },

    send(Handle, {sync_lsdb, LSAFilter}).

sync_nsm(Handle) when is_pid(Handle) ->
    send(Handle, sync_nsm).

sync_ism(Handle) when is_pid(Handle) ->
    send(Handle, sync_ism).
sync_router_id(Handle) when is_pid(Handle) ->
    send(Handle, sync_router_id).
sync_reachable(Handle) when is_pid(Handle) ->
    send(Handle, sync_reachable).
%% Internal functions

msg_type(?MSG_READY_NOTIFY) ->
    'MSG_READY_NOTIFY';
msg_type(?MSG_LSA_UPDATE_NOTIFY) ->
    'MSG_LSA_UPDATE_NOTIFY';
msg_type(?MSG_LSA_DELETE_NOTIFY) ->
    'MSG_LSA_DELETE_NOTIFY';
msg_type(?MSG_NEW_IF) ->
    'MSG_NEW_IF';
msg_type(?MSG_DEL_IF) ->
    'MSG_DEL_IF';
msg_type(?MSG_ISM_CHANGE) ->
    'MSG_ISM_CHANGE';
msg_type(?MSG_NSM_CHANGE) ->
    'MSG_NSM_CHANGE';
msg_type(?MSG_REACHABLE_CHANGE) ->
    'MSG_REACHABLE_CHANGE';
msg_type(?MSG_ROUTER_ID_CHANGE) ->
    'MSG_ROUTER_ID_CHANGE'.

msg_name(?MSG_REGISTER_OPAQUETYPE) ->
    "REGISTER_OPAQUETYPE";
msg_name(?MSG_UNREGISTER_OPAQUETYPE) ->
    "UNREGISTER_OPAQUETYPE";
msg_name(?MSG_REGISTER_EVENT) ->
    "REGISTER_EVENT";
msg_name(?MSG_SYNC_LSDB) ->
    "SYNC_LSDB";
msg_name(?MSG_ORIGINATE_REQUEST) ->
    "ORIGINATE_REQUEST";
msg_name(?MSG_DELETE_REQUEST) ->
    "DELETE_REQUEST";
msg_name(?MSG_SYNC_REACHABLE) ->
    "MSG_SYNC_REACHABLE";
msg_name(?MSG_SYNC_ISM) ->
    "MSG_SYNC_ISM";
msg_name(?MSG_SYNC_NSM) ->
    "MSG_SYNC_NSM";
msg_name(?MSG_SYNC_ROUTER_ID) ->
    "MSG_SYNC_ROUTER_ID";
msg_name(?MSG_REPLY) ->
    "REPLY";
msg_name(?MSG_READY_NOTIFY) ->
    "READY_NOTIFY";
msg_name(?MSG_LSA_UPDATE_NOTIFY) ->
    "LSA_UPDATE_NOTIFY";
msg_name(?MSG_LSA_DELETE_NOTIFY) ->
    "LSA_DELETE_NOTIFY";
msg_name(?MSG_NEW_IF) ->
    "NEW_IF";
msg_name(?MSG_DEL_IF) ->
    "DEL_IF";
msg_name(?MSG_ISM_CHANGE) ->
    "ISM_CHANGE";
msg_name(?MSG_NSM_CHANGE) ->
    "NSM_CHANGE";
msg_name(?MSG_REACHABLE_CHANGE) ->
    "REACHABLE_CHANGE";
msg_name(?MSG_ROUTER_ID_CHANGE) ->
    "ROUTER_ID_CHANGE".

msg_errname(?OSPF_API_OK) ->
    "OSPF_API_OK";
msg_errname(?OSPF_API_NOSUCHINTERFACE) ->
    "OSPF_API_NOSUCHINTERFACE";
msg_errname(?OSPF_API_NOSUCHAREA) ->
    "OSPF_API_NOSUCHAREA";
msg_errname(?OSPF_API_NOSUCHLSA) ->
    "OSPF_API_NOSUCHLSA";
msg_errname(?OSPF_API_ILLEGALLSATYPE) ->
    "OSPF_API_ILLEGALLSATYPE";
msg_errname(?OSPF_API_OPAQUETYPEINUSE) ->
    "OSPF_API_OPAQUETYPEINUSE";
msg_errname(?OSPF_API_OPAQUETYPENOTREGISTERED) ->
    "OSPF_API_OPAQUETYPENOTREGISTERED";
msg_errname(?OSPF_API_NOTREADY) ->
    "OSPF_API_NOTREADY";
msg_errname(?OSPF_API_NOMEMORY) ->
    "OSPF_API_NOMEMORY";
msg_errname(?OSPF_API_ERROR) ->
    "OSPF_API_ERROR";
msg_errname(?OSPF_API_UNDEF) ->
    "OSPF_API_UNDEF".

ism_name(?ISM_DEPENDUPON) ->
    "ISM_DEPENDUPON";
ism_name(?ISM_DOWN) ->
    "ISM_DOWN";
ism_name(?ISM_LOOPBACK) ->
    "ISM_LOOPBACK";
ism_name(?ISM_WAITING) ->
    "ISM_WAITING";
ism_name(?ISM_POINTTOPOINT) ->
    "ISM_POINTTOPOINT";
ism_name(?ISM_DROTHER) ->
    "ISM_DROTHER";
ism_name(?ISM_BACKUP) ->
    "ISM_BACKUP";
ism_name(?ISM_DR) ->
    "ISM_DR".

nsm_name(?NSM_DEPENDUPON) ->
    "NSM_DEPENDUPON";
nsm_name(?NSM_DELETED) ->
    "NSM_DELETED";
nsm_name(?NSM_DOWN) ->
    "NSM_DOWN";
nsm_name(?NSM_ATTEMPT) ->
    "NSM_ATTEMPT";
nsm_name(?NSM_INIT) ->
    "NSM_INIT";
nsm_name(?NSM_TWOWAY) ->
    "NSM_TWOWAY";
nsm_name(?NSM_EXSTART) ->
    "NSM_EXSTART";
nsm_name(?NSM_EXCHANGE) ->
    "NSM_EXCHANGE";
nsm_name(?NSM_LOADING) ->
    "NSM_LOADING";
nsm_name(?NSM_FULL) ->
    "NSM_FULL".

init(Host, Opts, Cpid) ->
    AsyncCallbacks = proplists:get_value(callbacks, Opts, #{}),
    AsyncCallbackData = proplists:get_value(callback_data, Opts, undefined),
    State = #ospfclient{
        host = Host, async_callbacks = AsyncCallbacks, async_callback_data = AsyncCallbackData
    },

    % We will not block the caller
    send(Cpid, {ok, self()}),

    % Send connect to itself in order to start connection procedures
    send(self(), connect),

    ?MODULE:loop(Cpid, State).

async_init(AsyncSocket, Callbacks, AsyncCallbackData) ->
    ?MODULE:async_loop(AsyncSocket, Callbacks, AsyncCallbackData).

try_connect(Cpid, State) ->
    case do_connect(State) of
        {ok, FdSync, FdAsync} ->
            AsyncPid = spawn_link(fun() ->
                async_init(
                    State#ospfclient.fd_async,
                    State#ospfclient.async_callbacks,
                    State#ospfclient.async_callback_data
                )
            end),
            ?MODULE:loop(Cpid, State#ospfclient{
                async_pid = AsyncPid, fd_sync = FdSync, fd_async = FdAsync
            });
        {error, not_connected, Reason} ->
            timer:sleep(?RETRY_CONNECT_TIMEOUT),
            io:format("Connect: ~p failed ~p~n", [State#ospfclient.host, Reason]),
            send(self(), connect),
            ?MODULE:loop(Cpid, State)
    end.

do_connect(State) ->
    Host = State#ospfclient.host,
    SyncPort = State#ospfclient.port,
    AsyncSockAddr = #{family => inet, addr => any, port => SyncPort + 1},
    maybe
        {ok, AsyncServerSocket} ?= socket:open(inet, stream, tcp),
        ok ?= socket:setopt(AsyncServerSocket, {socket, reuseaddr}, true),
        ok ?= socket:bind(AsyncServerSocket, AsyncSockAddr),
        ok ?= socket:listen(AsyncServerSocket),
        % Make a connection for synchronous requests and connect to server
        {ok, SyncSocket} ?= socket:open(inet, stream, tcp),
        ok ?= socket:setopt(SyncSocket, {socket, reuseaddr}, true),
        SockAddr = #{family => inet, addr => any, port => SyncPort},
        ok ?= socket:bind(SyncSocket, SockAddr),
        ok ?= socket:connect(SyncSocket, SockAddr#{addr => Host, port => ?OSPF_API_SYNC_PORT}),
        % Accept reverse connection
        {ok, AsyncSocket} ?= socket:accept(AsyncServerSocket),
        % Not needed anymore
        ok ?= socket:close(AsyncServerSocket),
        {ok, SyncSocket, AsyncSocket}
    else
        {error, Reason} ->
            {error, not_connected, Reason}
    end.

loop(Cpid, State) ->
    receive
        {_From, close} ->
            do_close(Cpid, State);
        {_From, connect} ->
            % It is not suppose to give up
            try_connect(Cpid, State);
        {_From, {sync_lsdb, LSAFilter}} ->
            State0 = do_sync_lsdb(LSAFilter, State),
            ?MODULE:loop(Cpid, State0);
        {_From, sync_nsm} ->
            State0 = do_sync_nsm(State),
            ?MODULE:loop(Cpid, State0);
        {_From, sync_ism} ->
            State0 = do_sync_ism(State),
            ?MODULE:loop(Cpid, State0);
        {_From, sync_router_id} ->
            State0 = do_sync_router_id(State),
            ?MODULE:loop(Cpid, State0);
        {_From, sync_reachable} ->
            State0 = do_sync_reachable(State),
            ?MODULE:loop(Cpid, State0)
    end.

async_loop(Socket, Callbacks, AsyncCallbackData) ->
    Msg = msg_read(Socket),
    MsgType = Msg#msg.hdr#apimsghdr.msgtype,
    Mt = msg_type(Msg#msg.hdr#apimsghdr.msgtype),
    MsgName = msg_name(MsgType),

    M = decode_async_msg(MsgType, Msg#msg.body),

    case maps:get(Mt, Callbacks, undefined) of
        undefined ->
            io:format("Handle not available for ~s payload ~p~n", [MsgName, M]);
        Callback ->
            io:format("RECV msg ~p/~p~n", [Mt, MsgType]),
            catch (Callback(MsgName, M, AsyncCallbackData))
    end,

    ?MODULE:async_loop(Socket, Callbacks, AsyncCallbackData).

do_close(Cpid, #ospfclient{async_pid = AsyncPid, fd_sync = FdSync, fd_async = FdAsync}) ->
    case AsyncPid of
        AsyncPid when is_pid(AsyncPid) ->
            erlang:unlink(AsyncPid),
            erlang:exit(AsyncPid, closed);
        _ ->
            ok
    end,
    case FdAsync of
        undefined ->
            ok;
        FdAsync ->
            _ = socket:close(FdAsync)
    end,
    case FdSync of
        undefined ->
            ok;
        FdSync ->
            socket:close(FdSync)
    end,
    erlang:unlink(Cpid),
    erlang:exit(normal).

do_sync_lsdb(LSAFilter, State) ->
    {State0, Seq0} = get_seqnr(State),
    Bin0 = new_msg_register_event(Seq0, LSAFilter),

    ok = send_request(State#ospfclient.fd_sync, Seq0, Bin0),

    {State1, Seq1} = get_seqnr(State0),

    Bin1 = new_msg_sync_lsdb(Seq1, LSAFilter),

    ok = send_request(State#ospfclient.fd_sync, Seq1, Bin1),

    State1.

do_sync_nsm(State) ->
    {State0, Seq} = get_seqnr(State),
    Bin = new_msg_sync_nsm(Seq),
    ok = send_request(State#ospfclient.fd_sync, Seq, Bin),
    State0.

do_sync_ism(State) ->
    {State0, Seq} = get_seqnr(State),
    Bin = new_msg_sync_ism(Seq),
    ok = send_request(State#ospfclient.fd_sync, Seq, Bin),
    State0.

do_sync_router_id(State) ->
    {State0, Seq} = get_seqnr(State),
    Bin = new_msg_sync_router_id(Seq),
    ok = send_request(State#ospfclient.fd_sync, Seq, Bin),
    State0.

do_sync_reachable(State) ->
    {State0, Seq} = get_seqnr(State),
    Bin = new_msg_sync_reachable(Seq),
    ok = send_request(State#ospfclient.fd_sync, Seq, Bin),
    State0.

% Send synchronous request, wait for reply
send_request(Socket, ReqSeq, Bin) ->
    ok = socket:send(Socket, Bin, [], infinity),

    % wait for reply
    Msg = msg_read(Socket),

    ?assertEqual(?MSG_REPLY, Msg#msg.hdr#apimsghdr.msgtype),
    ?assertEqual(Msg#msg.hdr#apimsghdr.msgseq, ReqSeq),

    case parse_msg(Msg) of
        ?OSPF_API_OK ->
            ok;
        Else ->
            Else
    end.

msg_read(Socket) ->
    {ok, DataHdr} = socket:recv(Socket, ?APIMSGHDR, [], infinity),

    Hdr = parse_msghdr(DataHdr),

    {ok, DataBody} = socket:recv(Socket, Hdr#apimsghdr.msglen, [], infinity),

    #msg{hdr = Hdr, body = DataBody}.

get_seqnr(#ospfclient{seqnr = Seqnr} = State) ->
    Seq = Seqnr + 1,
    {State#ospfclient{seqnr = Seq}, Seq}.

parse_msghdr(<<Version:8, MsgType:8, MsgLen:16, MsgSeq:32>>) ->
    #apimsghdr{version = Version, msgtype = MsgType, msglen = MsgLen, msgseq = MsgSeq}.

parse_msg(#msg{
    hdr = #apimsghdr{msgtype = ?MSG_REPLY},
    body = <<Errcode:8/little-integer-signed-unit:1, _/bitstring>>
}) ->
    Errcode.

msg_new(MsgType, MsgBody, SeqNum, MsgLen) ->
    <<?OSPF_API_VERSION:8, MsgType:8, MsgLen:16, SeqNum:32, MsgBody/binary>>.

new_msg_register_event(SeqNum, #lsa_filter_type{
    typemask = TMask, origin = Origin, num_areas = NumAreas
}) ->
    EventMsg = <<TMask:16, Origin:8, NumAreas:8>>,
    Len = byte_size(EventMsg),
    LenWithAreas = Len + NumAreas * 4,
    msg_new(?MSG_REGISTER_EVENT, EventMsg, SeqNum, LenWithAreas).

new_msg_sync_lsdb(SeqNum, #lsa_filter_type{typemask = TMask, origin = Origin, num_areas = NumAreas}) ->
    SyncMsg = <<TMask, Origin, NumAreas>>,
    Len = byte_size(SyncMsg),
    LenWithAreas = Len + NumAreas * 4,
    msg_new(?MSG_SYNC_LSDB, SyncMsg, SeqNum, LenWithAreas).

new_msg_sync_nsm(SeqNum) ->
    MsgBody = <<0:32>>,
    Len = byte_size(MsgBody),
    msg_new(?MSG_SYNC_NSM, MsgBody, SeqNum, Len).

new_msg_sync_ism(SeqNum) ->
    MsgBody = <<0:32>>,
    Len = byte_size(MsgBody),
    msg_new(?MSG_SYNC_ISM, MsgBody, SeqNum, Len).

new_msg_sync_router_id(SeqNum) ->
    MsgBody = <<0:32>>,
    Len = byte_size(MsgBody),
    msg_new(?MSG_SYNC_ROUTER_ID, MsgBody, SeqNum, Len).

new_msg_sync_reachable(SeqNum) ->
    MsgBody = <<0:32>>,
    Len = byte_size(MsgBody),
    msg_new(?MSG_SYNC_REACHABLE, MsgBody, SeqNum, Len).

decode_async_msg(?MSG_READY_NOTIFY, <<LsaType:8, OpaqueType:8, _Pad:24, Addr:32>>) ->
    #msg_ready_notify{lsa_type = LsaType, opaque_type = OpaqueType, addr = inet_ntoa(Addr)};
decode_async_msg(Mt, <<IfAddr:32, AreaId:32, IsSelfOriginated:8, _Pad:24, Data/binary>>) when
    Mt =:= ?MSG_LSA_UPDATE_NOTIFY; Mt =:= ?MSG_LSA_DELETE_NOTIFY
->
    #msg_lsa_change_notify{
        ifaddr = inet_ntoa(IfAddr),
        area_id = inet_ntoa(AreaId),
        is_self_originated = IsSelfOriginated,
        lsa_header = Data
    };
decode_async_msg(?MSG_NEW_IF, <<IfAddr:32, AreaId:32>>) ->
    #msg_new_if{ifaddr = inet_ntoa(IfAddr), area_id = AreaId};
decode_async_msg(?MSG_DEL_IF, <<IfAddr:32>>) ->
    #msg_del_if{ifaddr = inet_ntoa(IfAddr)};
decode_async_msg(?MSG_ISM_CHANGE, <<IfAddr:32, AreaId:32, Status:8, _Pad:24>>) ->
    #msg_ism_change{ifaddr = inet_ntoa(IfAddr), area_id = AreaId, status = Status};
decode_async_msg(?MSG_NSM_CHANGE, <<IfAddr:32, NbrAddr:32, RouterId:32, Status:8, _Pad:24>>) ->
    #msg_nsm_change{
        ifaddr = inet_ntoa(IfAddr),
        nbraddr = inet_ntoa(NbrAddr),
        router_id = inet_ntoa(RouterId),
        status = Status
    };
decode_async_msg(?MSG_ROUTER_ID_CHANGE, <<RouterId:32>>) ->
    #msg_router_id_change{
        router_id = inet_ntoa(RouterId)
    }.

%
% Misc. routines
%

send(To, Msg) ->
    To ! {self(), Msg},
    ok.

recv(From) ->
    receive
        {From, Msg} ->
            Msg;
        {'EXIT', From, Reason} ->
            {error, {internal_error, Reason}}
    end.

%% @doc Converts the given uint32 into a tuple with the
%% human-readable ip address representation, i.e: {x, x, x, x}.
-spec inet_ntoa(pos_integer()) -> tuple().
inet_ntoa(Num) ->
    B1 = (Num band 2#11111111000000000000000000000000) bsr 24,
    B2 = (Num band 2#00000000111111110000000000000000) bsr 16,
    B3 = (Num band 2#00000000000000001111111100000000) bsr 8,
    B4 = Num band 2#00000000000000000000000011111111,
    {B1, B2, B3, B4}.
