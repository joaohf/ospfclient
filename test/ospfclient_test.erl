-module(ospfclient_test).

-export([test/0, my/3]).

-include("ospfclient.hrl").

test() ->
    Callbacks = #{
        'MSG_NSM_CHANGE' => fun my/3
        % 'MSG_LSA_UPDATE_NOTIFY' => fun my/3,
        % 'MSG_LSA_DELETE_NOTIFY' => fun my/3
    },
    Opts = [{callbacks, Callbacks}, {callback_data, self()}],

    {ok, Handle} = ospfclient:connect({192, 168, 56, 102}, Opts),

    %ospfclient:sync_lsdb(Handle),

    Handle.

my(MsgName, #msg_nsm_change{} = M, CallbackData) ->
    io:format("callback mt ~p data ~p payload ~p~n", [MsgName, CallbackData, M]).
