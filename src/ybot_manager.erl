%%%----------------------------------------------------------------------
%%% File    : ybot_manager.erl
%%% Author  : 0xAX <anotherworldofworld@gmail.com>
%%% Purpose : Ybot main manager. Run transport, load plugins.
%%%----------------------------------------------------------------------
-module(ybot_manager).

-behaviour(gen_server).

-export([start_link/2, load_plugin/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-record(state, {
       % ybot transports list (irc, xmpp and etc..)
       % Example : [{irc, ClientPid, HandlerPid, Nick, Channel, Host}]
       transports = [],
       % Ybot active plugins list
       plugins = [] :: [{plugin, Source :: string(), PluginName :: string(), Path :: string()}],
       % Runned transports pid list
       runned_transports = [] :: [pid()] 
    }).

start_link(PluginsDirectory, Transports) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [PluginsDirectory, Transports], []).

init([PluginsDirectory, Transports]) ->
    % init plugins
    ok = gen_server:cast(?MODULE, {init_plugins, PluginsDirectory}),
    % Start transports
    ok = gen_server:cast(?MODULE, {start_transports, Transports}),
    % init command history process
    ok = gen_server:cast(?MODULE, init_history),
    % init
    {ok, #state{}}.

%% @doc Get plugin metadata by plugin name
handle_call({get_plugin, PluginName}, _From, State) ->
    case lists:keyfind(PluginName, 3, State#state.plugins) of
        false ->
            % there is no plugin with `PluginName`
            {reply, wrong_plugin, State};
        Plugin ->
            % return plugin with metadata
            {reply, Plugin, State}
    end;

%% @doc get all runned transports pid
handle_call(get_runnned_transports, _From, State) ->
    % Return all runned transports
    {reply, State#state.runned_transports, State};

%% @doc Return all plugins
handle_call(get_plugins, _From, State) ->
    % Return all plugins
    {reply, State#state.plugins, State};

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

%% @doc Init command history process
handle_cast(init_history, State) ->
    % Get 
    {ok, NeedCommandHistory} = application:get_env(ybot, commands_history),
    % Check need command history or not
    case NeedCommandHistory of
        true ->
            % Get history limit
            {ok, HistoryLimit} = application:get_env(ybot, history_command_limit_count),
            % start history process
            ybot_history:start_link(HistoryLimit);
        _ ->
            % do nothing
            ok
    end,
    % return
    {noreply, State};

%% @doc update plugins
handle_cast({update_plugins, NewPlugins}, State) ->
    % save new plugins
    {noreply, State#state{plugins = lists:flatten([NewPlugins | State#state.plugins])}};

%% @doc Init active plugins
handle_cast({init_plugins, PluginsDirectory}, State) ->
    case filelib:is_dir(PluginsDirectory) of
        true ->
            % Get all plugins
            PluginsPaths = ybot_utils:get_all_files(PluginsDirectory),
            % Parse plugins and load to state
            Plugins = lists:flatten(lists:map(fun load_plugin/1, PluginsPaths)),
            % Get checking_new_plugins parameter from config
            {ok, UseNewPlugins} = application:get_env(ybot, checking_new_plugins),
            % Check checking_new_plugins
            case UseNewPlugins of
                true ->
                    % Get new plugins checking timeout
                    {ok, NewPluginsCheckingTimeout} = application:get_env(ybot, checking_new_plugins_timeout),
                    % Start new plugins observer
                    ybot_plugins_observer:start_link(PluginsDirectory, PluginsPaths, NewPluginsCheckingTimeout);
                _ ->
                    % don't use new plugins
                    pass
            end,
            % return plugins
            {noreply, State#state{plugins = Plugins}};
        false ->
            % some log
            lager:error("Unable to load plugins. Invalid directory ~s", [PluginsDirectory]),
            % return empty plugins list
            {noreply, State#state{plugins = []}}
    end;

%% @doc Run transports from `Transports` list
handle_cast({start_transports, Transports}, State) ->
    % Review supported mode of transportation
    TransportList = lists:flatten(lists:map(fun load_transport/1, Transports)),
    % Get runned transports pid list
    RunnedTransport = lists:flatten(lists:map(fun(Transport) -> 
                                                  if erlang:element(1, Transport) == http ->
                                                      % we no need in http transport
                                                      [];
                                                  true ->
                                                      erlang:element(2, Transport) 
                                                  end 
                                              end, TransportList)),
    % Init transports
    {noreply, State#state{transports = TransportList, runned_transports = RunnedTransport}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

%% @doc Start irc clients
load_transport({irc, Nick, Channel, Host, Options}) ->
    % Validate transport options
    case ybot_validators:validate_transport_opts(Options) of
        ok ->
            % Get irc server port
            {port, Port} = lists:keyfind(port, 1, Options),
            % SSL?
            {use_ssl, UseSsl} = lists:keyfind(use_ssl, 1, Options),
            % Get reconnect timeout
            {reconnect_timeout, ReconnectTimeout} = lists:keyfind(reconnect_timeout, 1, Options),
            % Start irc handler
            {ok, HandlerPid} = irc_handler:start_link(),
            % Run new irc client
            {ok, ClientPid} = irc_lib_sup:start_irc_client(HandlerPid, Host, Port, Channel, Nick, UseSsl, ReconnectTimeout),
            lager:info("Starting IRC transport: ~p, ~p, ~s", [Host, Channel, Nick]),
            % send client pid to handler
            ok = gen_server:cast(HandlerPid, {irc_client, ClientPid, Nick}),
            % return correct transport
            {irc, ClientPid, HandlerPid, Nick, Channel, Host, Port};
        % wrong transport
        _ ->
            []
    end;

%% @doc start xmpp clients
load_transport({xmpp, Login, Password, Room, Host, Resource, Options}) ->
    % Validate transport options
    case ybot_validators:validate_transport_opts(Options) of
        ok ->
            % Get irc server port
            {port, Port} = lists:keyfind(port, 1, Options),
            % SSL?
            {use_ssl, UseSsl} = lists:keyfind(use_ssl, 1, Options),
            % Get reconnect timeout
            {reconnect_timeout, ReconnectTimeout} = lists:keyfind(reconnect_timeout, 1, Options),
            % Start xmpp handler
            {ok, HandlerPid} = xmpp_handler:start_link(),
            % Is hipchat
            ClientPid = case lists:keyfind(is_hipchat, 1, Options) of
                {_, false} -> 
                    % Make room
                    XmppRoom = list_to_binary(binary_to_list(Room) ++ "/" ++ binary_to_list(Login)),
                    % Log
                    lager:info("Starting XMPP transport: ~s, ~s, ~s", [Host, Room, Resource]),
                    {ok, CPid} = xmpp_sup:start_xmpp_client(HandlerPid, Login, Password, Host, Port, XmppRoom, Resource, UseSsl, ReconnectTimeout),
                    % Send client pid to handler
                    ok = gen_server:cast(HandlerPid, {xmpp_client, CPid, Login}),
                    % return xmpp client pid
                    CPid;
                % This is hipchat
                {_, true} ->
                    % Get hipchat nick
                    {_, HipChatNick}  = lists:keyfind(hipchat_nick, 1, Options),
                    % Make room
                    XmppRoom = list_to_binary(binary_to_list(Room) ++ "/" ++ binary_to_list(HipChatNick)), 
                    % Run new xmpp client
                    {ok, CPid} = xmpp_sup:start_xmpp_client(HandlerPid, Login, Password, Host, Port, XmppRoom, Resource, UseSsl, ReconnectTimeout),
                    % Send client pid to handler
                    ok = gen_server:cast(HandlerPid, {xmpp_client, CPid, 
                        list_to_binary("@" ++ lists:concat(string:tokens(binary_to_list(HipChatNick), " ")))}),
                    % return xmpp client pid
                    CPid
            end,
            % return correct transport
            {xmpp, ClientPid, HandlerPid, Login, Password, Host, Room, Resource};
        % wrong options
        _ ->
            []
    end;

%% @doc start campfire clients
load_transport({campfire, Login, Token, RoomId, CampfireSubDomain, Options}) ->
    % Get reconnect timeout
    {reconnect_timeout, ReconnectTimeout} = lists:keyfind(reconnect_timeout, 1, Options),
    % Start campfire handler
    {ok, HandlerPid} = campfire_handler:start_link(),
    % Run new campfire client
    {ok, ClientPid} = campfire_sup:start_campfire_client(HandlerPid, RoomId, Token, CampfireSubDomain, ReconnectTimeout),
    % Log
    lager:info("Starting Campfire transport: ~p, ~s", [RoomId, CampfireSubDomain]),
    % Send client pid to handler
    ok = gen_server:cast(HandlerPid, {campfire_client, ClientPid, Login}),
    % return correct transport
    {campfire, ClientPid, HandlerPid};

%% @doc Ybot http interface
load_transport({http, Host, Port, BotNick}) ->
    % Start http server
    {ok, HttpPid} = http_sup:start_http(Host, Port),
    % Log
    lager:info("Starting http transport ~p:~p", [Host, Port]),
    % Send bot nick to http server
    ok = gen_server:cast(HttpPid, {bot_nick, BotNick}),
    % return correct transport
    {http, HttpPid}.

load_plugin(Plugin) ->
    % Get plugin extension
    Ext = filename:extension(Plugin),
    Name = filename:basename(Plugin, Ext),
    % Match extension
    case Ext of
        ".py" ->
            % python plugin
            lager:info("Loading plugin(Python): ~s", [Name]),
            {plugin, "python", Name, Plugin};
        ".rb" ->
            % ruby plugin
            lager:info("Loading plugin(Ruby): ~s", [Name]),
            {plugin, "ruby", Name, Plugin};
        ".sh" ->
            % shell plugin
            lager:info("Loading plugin(Shell): ~s", [Name]),
            {plugin, "sh", Name, Plugin};
        ".pl" ->
            % perl plugin
            lager:info("Loading plugin(Perl) ~s", [Name]),
            {plugins, "perl", Name, Plugin};
        ".ex" ->
            % elixir plugin
            lager:info("Loading plugin(Elixir) ~s", [Name]),
            {plugins, "elixir", Name, Plugin};
        _ ->
            % this is wrong plugin
            lager:info("Unsupported plugin type: ~s", [Ext]),
            []
    end.
