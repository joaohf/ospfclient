-define(NON_SELF_ORIGINATED, 0).
-define(SELF_ORIGINATED, 1).
-define(ANY_ORIGIN, 2).

-type lsa_origin() :: ?NON_SELF_ORIGINATED | ?SELF_ORIGINATED | ?ANY_ORIGIN.

-record(lsa_filter_type, {
    typemask :: 0..65535,
    origin :: lsa_origin(),
    num_areas :: 0..255
}).

% https://github.com/FRRouting/frr/blob/3d2c589766a7bd8694bcbdb8c6979178d1f2d811/ospfd/ospf_api.h

% Message to tell client application that it ospf daemon is
% ready to accept opaque LSAs for a given interface or area.

-record(msg_ready_notify, {
    lsa_type,
    opaque_type,
    % interface address or area address
    addr
}).

-record(msg_lsa_change_notify, {
    % Used for LSA type 9 otherwise ignored
    ifaddr,
    % Area ID. Not valid for AS-External and Opaque11 LSAs.
    area_id,
    % 1 if self originated.
    is_self_originated,
    lsa_header
}).

-record(msg_ism_change, {
    % interface IP address
    ifaddr,
    % area this interface belongs to
    area_id,
    % interface status (up/down)
    status
}).

-record(msg_new_if, {
    % interface IP address
    ifaddr,
    % area this interface belongs to
    area_id
}).

-record(msg_del_if, {
    % interface IP address
    ifaddr
}).

-record(msg_nsm_change, {
    % attached interface
    ifaddr,
    % Neighbor interface address
    nbraddr,
    % Router ID of neighbor
    router_id,
    % NSM status
    status
}).

-record(msg_router_id_change, {
    % this systems router id
    router_id
}).
