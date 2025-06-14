defmodule Hedwig.Adapters.IRC do
  @moduledoc false

  use Hedwig.Adapter

  alias ExIRC.Client
  alias ExIRC.SenderInfo
  alias Hedwig.Message
  alias Hedwig.Robot
  alias Hedwig.User

  require Logger

  def init({robot, opts}) do
    Logger.debug("#{inspect(opts)}")
    {:ok, client} = ExIRC.start_client!()
    ExIRC.Client.add_handler(client, self())
    Kernel.send(self(), :connect)
    {:ok, {robot, opts, client}}
  end

  def handle_cast({:send, %{text: text, room: channel}}, {_robot, _opts, client} = state) do
    for line <- String.split(text, "\n") do
      Client.msg(client, :privmsg, channel, line)
    end

    {:noreply, state}
  end

  def handle_cast({:reply, %{text: text, user: user, room: channel}}, {_robot, _opts, client} = state) do
    Client.msg(client, :privmsg, channel, user.name <> ": " <> text)
    {:noreply, state}
  end

  def handle_cast({:emote, %{text: text, room: channel}}, {_robot, _opts, client} = state) do
    Client.me(client, channel, text)
    {:noreply, state}
  end

  def handle_info(:connect, {_robot, opts, client} = state) do
    host = Keyword.fetch!(opts, :server)
    port = Keyword.get(opts, :port, 6667)
    ssl? = Keyword.get(opts, :ssl?, false)

    if ssl? do
      Client.connect_ssl!(client, host, port)
    else
      Client.connect!(client, host, port)
    end

    {:noreply, state}
  end

  def handle_info({:connected, server, port}, {robot, opts, client} = state) do
    Logger.info("Connected to #{server}:#{port}")
    pass = Keyword.fetch!(opts, :password)
    nick = Keyword.fetch!(opts, :name)
    user = Keyword.get(opts, :irc_user, nick)
    name = Keyword.get(opts, :full_name, nick)
    Client.logon(client, pass, nick, user, name)
    :ok = Robot.handle_connect(robot)
    {:noreply, state}
  end

  def handle_info(:logged_in, {_robot, opts, client} = state) do
    Logger.info("Logged in")
    rooms = Keyword.fetch!(opts, :rooms)

    for {channel, password} <- rooms do
      Client.join(client, channel, password)
    end

    {:noreply, state}
  end

  def handle_info({:mentioned, _msg, _user, _channel}, state) do
    {:noreply, state}
  end

  def handle_info({:received, msg, %SenderInfo{} = user, channel}, {robot, _opts, _client} = state) do
    incoming_message = %Message{
      ref: make_ref(),
      robot: robot,
      room: channel,
      text: msg,
      user: %User{id: "#{user.user}@#{user.host}", name: user.nick},
      type: "groupchat"
    }

    Robot.handle_in(robot, incoming_message)

    {:noreply, state}
  end

  def handle_info({:quit, message, %{nick: user}}, state) do
    Logger.info("#{user} left with message: #{inspect(message)}")
    {:noreply, state}
  end

  def handle_info(:disconnected, {robot, opts, client} = state) do
    Robot.handle_disconnect(robot, nil)
    Logger.warn("Disconnected from server. Attempting to reconnect in 5 seconds...")
    Process.send_after(self(), :reconnect, 5000)
    {:noreply, {robot, opts, client}}
  end

  def handle_info(:reconnect, {_robot, opts, client} = state) do
    host = Keyword.fetch!(opts, :server)
    port = Keyword.get(opts, :port, 6667)
    ssl? = Keyword.get(opts, :ssl, false)

    if ssl? do
      Client.connect_ssl!(client, host, port)
    else
      Client.connect!(client, host, port)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unknown message: #{inspect(msg)}")
    {:noreply, state}
  end
end
