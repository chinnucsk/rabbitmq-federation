%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%

-module(rabbit_federation_link).

-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_federation.hrl").

-behaviour(gen_server2).

-export([go/0, add_binding/3, remove_bindings/3, stop/1]).
-export([list_routing_keys/1]). %% For testing

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-import(rabbit_misc, [pget/2]).
-import(rabbit_federation_util, [name/1]).
-import(rabbit_federation_util, [vhost/1]).

-record(state, {upstream,
                connection,
                channel,
                consumer_tag,
                queue,
                internal_exchange,
                waiting_cmds = gb_trees:empty(),
                next_serial,
                bindings = dict:new(),
                downstream_connection,
                downstream_channel,
                downstream_exchange,
                unacked = gb_trees:empty()}).

%%----------------------------------------------------------------------------

%% We start off in a state where we do not connect, since we can first
%% start during exchange recovery, when rabbit is not fully started
%% and the Erlang client is not running. This then gets invoked when
%% the federation app is started.
go() -> cast(go).

add_binding(S, XN, B)      -> cast(XN, {enqueue, S, {add_binding, B}}).
remove_bindings(S, XN, Bs) -> cast(XN, {enqueue, S, {remove_bindings, Bs}}).

%% This doesn't just correspond to the link being killed by its
%% supervisor since this means "the exchange is going away, please
%% remove upstream resources associated with it".
stop(XN) -> call(XN, stop).

list_routing_keys(XN) -> call(XN, list_routing_keys).

%%----------------------------------------------------------------------------

start_link(Args) ->
    gen_server2:start_link(?MODULE, Args, [{timeout, infinity}]).

init(Args = {Upstream, XName}) ->
    rabbit_federation_status:report(Upstream, XName, starting),
    join(rabbit_federation_exchanges),
    join({rabbit_federation_exchange, XName}),
    gen_server2:cast(self(), maybe_go),
    {ok, {not_started, Args}}.

handle_call(list_routing_keys, _From, State = #state{bindings = Bindings}) ->
    {reply, lists:sort([K || {K, _} <- dict:fetch_keys(Bindings)]), State};

handle_call(stop, _From, State = #state{connection = Conn, queue = Q}) ->
    disposable_channel_call(Conn, #'queue.delete'{queue = Q}),
    {stop, normal, ok, State};

handle_call(Msg, _From, State) ->
    {stop, {unexpected_call, Msg}, State}.

handle_cast(maybe_go, S0 = {not_started, _Args}) ->
    case federation_up() of
        true  -> go(S0);
        false -> {noreply, S0}
    end;

handle_cast(go, S0 = {not_started, _Args}) ->
    go(S0);

%% There's a small race - I think we can realise federation is up
%% before 'go' gets invoked. Ignore.
handle_cast(go, State) ->
    {noreply, State};

handle_cast({enqueue, _, _}, State = {not_started, _}) ->
    {noreply, State};

handle_cast({enqueue, Serial, Cmd}, State = #state{waiting_cmds = Waiting}) ->
    Waiting1 = gb_trees:insert(Serial, Cmd, Waiting),
    {noreply, play_back_commands(State#state{waiting_cmds = Waiting1})};

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info(#'basic.ack'{delivery_tag = Seq, multiple = Multiple},
            State = #state{unacked = Unacked}) ->
    ack(gb_trees:get(Seq, Unacked), Multiple, State),
    {noreply, State#state{unacked = remove_delivery_tags(Seq, Multiple,
                                                         Unacked)}};

handle_info({#'basic.deliver'{routing_key  = Key,
                              delivery_tag = DTag,
                              redelivered  = Redelivered}, Msg},
            State = #state{
              upstream            = #upstream{max_hops      = MaxHops,
                                              trust_user_id = Trust} = Upstream,
              downstream_exchange = #resource{name = XNameBin},
              downstream_channel  = DCh,
              unacked             = Unacked}) ->
    Headers0 = extract_headers(Msg),
    %% TODO add user information here?
    %% We need to check should_forward/2 here in case the upstream
    %% does not have federation and thus is using a fanout exchange.
    case rabbit_federation_util:should_forward(Headers0, MaxHops) of
        true  -> {table, Info0} = rabbit_federation_upstream:to_table(Upstream),
                 Info = Info0 ++ [{<<"redelivered">>, bool, Redelivered}],
                 Headers = rabbit_basic:append_table_header(
                             ?ROUTING_HEADER, Info, Headers0),
                 Seq = amqp_channel:next_publish_seqno(DCh),
                 amqp_channel:cast(DCh, #'basic.publish'{exchange    = XNameBin,
                                                         routing_key = Key},
                                   maybe_clear_user_id(
                                     Trust, update_headers(Headers, Msg))),
                 {noreply, State#state{unacked = gb_trees:insert(Seq, DTag,
                                                                 Unacked)}};
        false -> ack(DTag, false, State), %% Drop it, but acknowledge it!
                 {noreply, State}
    end;

handle_info(#'basic.cancel'{}, State) ->
    connection_error(local, basic_cancel, State);

%% If the downstream channel shuts down cleanly, we can just ignore it
%% - we're the same node, we're presumably about to go down too.
handle_info({'DOWN', _Ref, process, Ch, shutdown},
            State = #state{downstream_channel = Ch}) ->
    {noreply, State};

%% If the upstream channel goes down for an intelligible reason, just
%% log it and die quietly.
handle_info({'DOWN', _Ref, process, Ch, {shutdown, Reason}},
            State = #state{channel = Ch}) ->
    connection_error(remote, {upstream_channel_down, Reason}, State);

handle_info({'DOWN', _Ref, process, Ch, Reason},
            State = #state{channel = Ch}) ->
    {stop, {upstream_channel_down, Reason}, State};

handle_info({'DOWN', _Ref, process, Ch, Reason},
            State = #state{downstream_channel = Ch}) ->
    {stop, {downstream_channel_down, Reason}, State};

handle_info(Msg, State) ->
    {stop, {unexpected_info, Msg}, State}.

terminate(_Reason, {not_started, _}) ->
    ok;

terminate(Reason, State = #state{downstream_channel    = DCh,
                                 downstream_connection = DConn,
                                 connection            = Conn,
                                 channel               = Ch}) ->
    ensure_closed(DConn, DCh),
    ensure_closed(Conn, Ch),
    log_terminate(Reason, State),
    ok.

log_terminate({shutdown, restart}, _State) ->
    %% We've already logged this before munging the reason
    ok;
log_terminate(shutdown, #state{downstream_exchange = XName,
                               upstream            = Upstream}) ->
    %% The supervisor is shutting us down; we are probably restarting
    %% the link because configuration has changed. So try to shut down
    %% nicely so that we do not cause unacked messages to be
    %% redelivered.
    rabbit_log:info("Federation ~s disconnecting from ~s~n",
                    [rabbit_misc:rs(XName),
                     rabbit_federation_upstream:to_string(Upstream)]),
    rabbit_federation_status:remove(Upstream, XName);

log_terminate(Reason, #state{downstream_exchange = XName,
                             upstream            = Upstream}) ->
    %% Unexpected death. sasl will log it, but we should update
    %% rabbit_federation_status.
    rabbit_federation_status:report(Upstream, XName, clean_reason(Reason)).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

call(XName, Msg) -> [gen_server2:call(Pid, Msg, infinity) || Pid <- x(XName)].
cast(Msg)        -> [gen_server2:cast(Pid, Msg) || Pid <- all()].
cast(XName, Msg) -> [gen_server2:cast(Pid, Msg) || Pid <- x(XName)].

join(Name) ->
    pg2_fixed:create(Name),
    ok = pg2_fixed:join(Name, self()).

all() ->
    pg2_fixed:create(rabbit_federation_exchanges),
    pg2_fixed:get_members(rabbit_federation_exchanges).

x(XName) ->
    pg2_fixed:create({rabbit_federation_exchange, XName}),
    pg2_fixed:get_members({rabbit_federation_exchange, XName}).

%%----------------------------------------------------------------------------

federation_up() ->
    proplists:is_defined(rabbitmq_federation,
                         application:which_applications(infinity)).

handle_command({add_binding, Binding}, State) ->
    add_binding(Binding, State);

handle_command({remove_bindings, Bindings}, State) ->
    lists:foldl(fun remove_binding/2, State, Bindings).

play_back_commands(State = #state{waiting_cmds = Waiting,
                                  next_serial  = Next}) ->
    case gb_trees:is_empty(Waiting) of
        false -> case gb_trees:take_smallest(Waiting) of
                     {Next, Cmd, Waiting1} ->
                         %% The next one. Just execute it.
                         play_back_commands(
                           handle_command(Cmd, State#state{
                                                 waiting_cmds = Waiting1,
                                                 next_serial  = Next + 1}));
                     {Serial, _Cmd, Waiting1} when Serial < Next ->
                         %% This command came from before we executed
                         %% binding:list_for_source. Ignore it.
                         play_back_commands(State#state{
                                              waiting_cmds = Waiting1});
                     _ ->
                         %% Some future command. Don't do anything.
                         State
                 end;
        true  -> State
    end.

open_monitor(Params) ->
    case open(Params) of
        {ok, Conn, Ch} -> erlang:monitor(process, Ch),
                          {ok, Conn, Ch};
        E              -> E
    end.

open(Params) ->
    case amqp_connection:start(Params) of
        {ok, Conn} -> case amqp_connection:open_channel(Conn) of
                          {ok, Ch} -> {ok, Conn, Ch};
                          E        -> catch amqp_connection:close(Conn),
                                      E
                      end;
        E -> E
    end.

add_binding(B, State) ->
    binding_op(fun record_binding/2, bind_cmd(bind, B, State), B, State).

remove_binding(B, State) ->
    binding_op(fun forget_binding/2, bind_cmd(unbind, B, State), B, State).

record_binding(B = #binding{destination = Dest},
               State = #state{bindings = Bs}) ->
    {DoIt, Set} = case dict:find(key(B), Bs) of
                      error       -> {true,  sets:from_list([Dest])};
                      {ok, Dests} -> {false, sets:add_element(
                                               Dest, Dests)}
                  end,
    {DoIt, State#state{bindings = dict:store(key(B), Set, Bs)}}.

forget_binding(B = #binding{destination = Dest},
               State = #state{bindings = Bs}) ->
    Dests = sets:del_element(Dest, dict:fetch(key(B), Bs)),
    {DoIt, Bs1} = case sets:size(Dests) of
                      0 -> {true,  dict:erase(key(B), Bs)};
                      _ -> {false, dict:store(key(B), Dests, Bs)}
                  end,
    {DoIt, State#state{bindings = Bs1}}.

binding_op(UpdateFun, Cmd, B = #binding{args = Args},
           State = #state{channel = Ch,
                          upstream = #upstream{max_hops = MaxHops}}) ->
    {DoIt, State1} =
        case rabbit_misc:table_lookup(Args, ?BINDING_HEADER) of
            undefined  -> UpdateFun(B, State);
            %% TODO: this is wrong, see logic on whiteboard
            {array, A} -> {length(A) < MaxHops, State}
        end,
    case DoIt of
        true  -> amqp_channel:call(Ch, Cmd);
        false -> ok
    end,
    State1.

bind_cmd(Type, #binding{key = Key, args = Args},
         State = #state{internal_exchange = IntXNameBin,
                        upstream          = Upstream}) ->
    #upstream{exchange = X} = Upstream,
    bind_cmd0(Type, name(X), IntXNameBin, Key,
              update_binding(Args, State)).

bind_cmd0(bind, Source, Destination, RoutingKey, Arguments) ->
    #'exchange.bind'{source      = Source,
                     destination = Destination,
                     routing_key = RoutingKey,
                     arguments   = Arguments};

bind_cmd0(unbind, Source, Destination, RoutingKey, Arguments) ->
    #'exchange.unbind'{source      = Source,
                       destination = Destination,
                       routing_key = RoutingKey,
                       arguments   = Arguments}.

update_binding(Args, #state{downstream_exchange = X}) ->
    Node = rabbit_federation_util:local_nodename(vhost(X)),
    Info = [{<<"node">>,         longstr, Node},
            {<<"virtual_host">>, longstr, vhost(X)},
            {<<"exchange">>,     longstr, name(X)}],
    rabbit_basic:append_table_header(?BINDING_HEADER, Info, Args).

key(#binding{key = Key, args = Args}) -> {Key, Args}.

go(S0 = {not_started, {Upstream, DownXName =
                           #resource{virtual_host = DownVHost}}}) ->
    %% We trap exits so terminate/2 gets called. Note that this is not
    %% in init() since we need to cope with the link getting restarted
    %% during shutdown (when a broker federates with itself), which
    %% means we hang in federation_up() and the supervisor must force
    %% us to exit. We can therefore only trap exits when past that
    %% point. Bug 24372 may help us do something nicer.
    process_flag(trap_exit, true),
    case open_monitor(
           rabbit_federation_util:local_params(Upstream, DownVHost)) of
        {ok, DConn, DCh} ->
            #'confirm.select_ok'{} =
               amqp_channel:call(DCh, #'confirm.select'{}),
            amqp_channel:register_confirm_handler(DCh, self()),
            case open_monitor(Upstream#upstream.params) of
                {ok, Conn, Ch} ->
                    {Serial, Bindings} =
                        rabbit_misc:execute_mnesia_transaction(
                          fun () ->
                                  {rabbit_exchange:peek_serial(DownXName),
                                   rabbit_binding:list_for_source(DownXName)}
                          end),
                    true = is_integer(Serial),
                    %% If we are very short lived, Serial can be undefined at
                    %% this point (since the deletion of the X could have
                    %% overtaken the creation of this process). However, this
                    %% is not a big deal - 'undefined' just becomes the next
                    %% serial we will process. Since it compares larger than
                    %% any number we never process any commands. And we will
                    %% soon get told to stop anyway.
                    try
                        State = ensure_upstream_bindings(
                                  consume_from_upstream_queue(
                                    #state{upstream              = Upstream,
                                           connection            = Conn,
                                           channel               = Ch,
                                           next_serial           = Serial,
                                           downstream_connection = DConn,
                                           downstream_channel    = DCh,
                                       downstream_exchange   = DownXName}),
                                  Bindings),
                        rabbit_log:info("Federation ~s connected to ~s~n",
                                        [rabbit_misc:rs(DownXName),
                                         rabbit_federation_upstream:to_string(
                                           Upstream)]),
                        Name = pget(name, amqp_connection:info(DConn, [name])),
                        rabbit_federation_status:report(
                          Upstream, DownXName, {running, Name}),
                        {noreply, State}
                    catch exit:E ->
                            %% terminate/2 will not get this, as we
                            %% have not put them in our state yet
                            ensure_closed(DConn, DCh),
                            ensure_closed(Conn, Ch),
                            connection_error(remote, E, S0)
                    end;
                E ->
                    ensure_closed(DConn, DCh),
                    connection_error(remote, E, S0)
            end;
        E ->
            connection_error(local, E, S0)
    end.

connection_error(remote, E, State = {not_started, {U, XName}}) ->
    rabbit_federation_status:report(U, XName, clean_reason(E)),
    rabbit_log:warning("Federation ~s did not connect to ~s~n~p~n",
                       [rabbit_misc:rs(XName),
                        rabbit_federation_upstream:to_string(U), E]),
    {stop, {shutdown, restart}, State};

connection_error(remote, E, State = #state{upstream            = U,
                                           downstream_exchange = XName}) ->
    rabbit_federation_status:report(U, XName, clean_reason(E)),
    rabbit_log:info("Federation ~s disconnected from ~s~n~p~n",
                    [rabbit_misc:rs(XName),
                     rabbit_federation_upstream:to_string(U), E]),
    {stop, {shutdown, restart}, State};

connection_error(local, basic_cancel,
                 State = #state{upstream            = U,
                                downstream_exchange = XName}) ->
    rabbit_federation_status:report(U, XName, {error, basic_cancel}),
    rabbit_log:info("Federation ~s received 'basic.cancel'~n",
                    [rabbit_misc:rs(XName)]),
    {stop, {shutdown, restart}, State};

connection_error(local, E, State = {not_started, {U, XName}}) ->
    rabbit_federation_status:report(U, XName, clean_reason(E)),
    rabbit_log:warning("Federation ~s did not connect locally~n~p~n",
                       [rabbit_misc:rs(XName), E]),
    {stop, {shutdown, restart}, State}.

%% If we terminate due to a gen_server call exploding (almost
%% certainly due to an amqp_channel:call() exploding) then we do not
%% want to report the gen_server call in our status.
clean_reason({E = {shutdown, _}, _}) -> E;
clean_reason(E)                      -> E.

%% local / disconnected never gets invoked, see handle_info({'DOWN', ...

consume_from_upstream_queue(
  State = #state{upstream            = Upstream,
                 channel             = Ch,
                 downstream_exchange = DownXName}) ->
    #upstream{exchange       = X,
              prefetch_count = Prefetch,
              expires        = Expiry,
              message_ttl    = TTL,
              ha_policy      = HA,
              params         = Params}
        = Upstream,
    Q = upstream_queue_name(name(X), vhost(Params), DownXName),
    Args = [Arg || {_K, _T, V} = Arg <- [{<<"x-expires">>,     long,    Expiry},
                                         {<<"x-message-ttl">>, long,    TTL},
                                         {<<"x-ha-policy">>,   longstr, HA}],
                   V =/= none],
    amqp_channel:call(Ch, #'queue.declare'{queue     = Q,
                                           durable   = true,
                                           arguments = Args}),
    amqp_channel:call(Ch, #'basic.qos'{prefetch_count = Prefetch}),
    #'basic.consume_ok'{consumer_tag = CTag} =
        amqp_channel:subscribe(Ch, #'basic.consume'{queue  = Q,
                                                    no_ack = false}, self()),
    State#state{consumer_tag = CTag,
                queue        = Q}.

ensure_upstream_bindings(State = #state{upstream            = Upstream,
                                        connection          = Conn,
                                        channel             = Ch,
                                        downstream_exchange = DownXName,
                                        queue               = Q}, Bindings) ->
    #upstream{exchange = X, params = Params} = Upstream,
    OldSuffix = rabbit_federation_db:get_active_suffix(
                  DownXName, Upstream, <<"A">>),
    Suffix = case OldSuffix of
                 <<"A">> -> <<"B">>;
                 <<"B">> -> <<"A">>
             end,
    IntXNameBin = upstream_exchange_name(name(X), vhost(Params),
                                         DownXName, Suffix),
    ensure_upstream_exchange(State),
    ensure_internal_exchange(IntXNameBin, State),
    amqp_channel:call(Ch, #'queue.bind'{exchange = IntXNameBin, queue = Q}),
    State1 = State#state{internal_exchange = IntXNameBin},
    State2 = lists:foldl(fun add_binding/2, State1, Bindings),
    rabbit_federation_db:set_active_suffix(DownXName, Upstream, Suffix),
    OldIntXNameBin = upstream_exchange_name(
                       name(X), vhost(Params), DownXName, OldSuffix),
    delete_upstream_exchange(Conn, OldIntXNameBin),
    State2.

ensure_upstream_exchange(#state{upstream   = #upstream{exchange = X},
                                connection = Conn,
                                channel    = Ch}) ->
    #exchange{type        = Type,
              durable     = Durable,
              auto_delete = AutoDelete,
              internal    = Internal,
              arguments   = Arguments} = X,
    Decl = #'exchange.declare'{exchange    = name(X),
                               type        = list_to_binary(atom_to_list(Type)),
                               durable     = Durable,
                               auto_delete = AutoDelete,
                               internal    = Internal,
                               arguments   = Arguments},
    disposable_channel_call(Conn, Decl#'exchange.declare'{passive = true},
                           fun(?NOT_FOUND, _Text) ->
                                   amqp_channel:call(Ch, Decl)
                           end).

ensure_internal_exchange(IntXNameBin,
                         #state{upstream   = #upstream{max_hops = MaxHops,
                                                       params   = Params},
                                connection = Conn,
                                channel    = Ch}) ->
    delete_upstream_exchange(Conn, IntXNameBin),
    Base = #'exchange.declare'{exchange    = IntXNameBin,
                               durable     = true,
                               internal    = true,
                               auto_delete = true},
    XFU = Base#'exchange.declare'{type      = <<"x-federation-upstream">>,
                                  arguments = [{?MAX_HOPS_ARG, long, MaxHops}]},
    Fan = Base#'exchange.declare'{type = <<"fanout">>},
    disposable_connection_call(Params, XFU, fun(?COMMAND_INVALID, _Text) ->
                                                    amqp_channel:call(Ch, Fan)
                                            end).

upstream_queue_name(XNameBin, VHost, #resource{name         = DownXNameBin,
                                               virtual_host = DownVHost}) ->
    Node = rabbit_federation_util:local_nodename(VHost),
    DownPart = case DownVHost of
                   VHost -> case DownXNameBin of
                                XNameBin -> <<"">>;
                                _        -> <<":", DownXNameBin/binary>>
                            end;
                   _     -> <<":", DownVHost/binary,
                              ":", DownXNameBin/binary>>
               end,
    <<"federation: ", XNameBin/binary, " -> ", Node/binary, DownPart/binary>>.

upstream_exchange_name(XNameBin, VHost, DownXName, Suffix) ->
    Name = upstream_queue_name(XNameBin, VHost, DownXName),
    <<Name/binary, " ", Suffix/binary>>.

delete_upstream_exchange(Conn, XNameBin) ->
    disposable_channel_call(Conn, #'exchange.delete'{exchange = XNameBin}).

disposable_channel_call(Conn, Method) ->
    disposable_channel_call(Conn, Method, fun(_, _) -> ok end).

disposable_channel_call(Conn, Method, ErrFun) ->
    {ok, Ch} = amqp_connection:open_channel(Conn),
    try
        amqp_channel:call(Ch, Method)
    catch exit:{{shutdown, {server_initiated_close, Code, Text}}, _} ->
            ErrFun(Code, Text)
    end,
    ensure_closed(Ch).

disposable_connection_call(Params, Method, ErrFun) ->
    case open(Params) of
        {ok, Conn, Ch} ->
            try
                amqp_channel:call(Ch, Method)
            catch exit:{{shutdown, {connection_closing,
                                    {server_initiated_close, Code, Txt}}}, _} ->
                    ErrFun(Code, Txt)
            end,
            ensure_closed(Conn, Ch);
        E ->
            E
    end.

ensure_closed(Conn, Ch) ->
    ensure_closed(Ch),
    catch amqp_connection:close(Conn).

ensure_closed(Ch) ->
    catch amqp_channel:close(Ch).

ack(Tag, Multiple, #state{channel = Ch}) ->
    amqp_channel:cast(Ch, #'basic.ack'{delivery_tag = Tag,
                                       multiple     = Multiple}).

remove_delivery_tags(Seq, false, Unacked) ->
    gb_trees:delete(Seq, Unacked);
remove_delivery_tags(Seq, true, Unacked) ->
    case gb_trees:is_empty(Unacked) of
        true  -> Unacked;
        false -> {Smallest, _Val, Unacked1} = gb_trees:take_smallest(Unacked),
                 case Smallest > Seq of
                     true  -> Unacked;
                     false -> remove_delivery_tags(Seq, true, Unacked1)
                 end
    end.

extract_headers(#amqp_msg{props = #'P_basic'{headers = Headers}}) ->
    Headers.

maybe_clear_user_id(false, Msg = #amqp_msg{props = Props}) ->
    Msg#amqp_msg{props = Props#'P_basic'{user_id = undefined}};
maybe_clear_user_id(true, Msg) ->
    Msg.

update_headers(Headers, Msg = #amqp_msg{props = Props}) ->
    Msg#amqp_msg{props = Props#'P_basic'{headers = Headers}}.
