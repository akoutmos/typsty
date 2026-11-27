defmodule Typsty.Test.RemoteRegistry do
  @moduledoc false
  # A registry (for {:via, module, name} names) whose names are all on another node

  def whereis_name(_name) do
    # A pid on remote@host, in the external term format: NEW_PID_EXT, with the node as a
    # SMALL_ATOM_UTF8_EXT, then the id, serial and creation
    :erlang.binary_to_term(<<131, 88, 119, 11, "remote@host", 1::32, 0::32, 1::32>>)
  end

  def register_name(_name, _pid), do: :no
  def unregister_name(_name), do: :ok
  def send(_name, message), do: message
end
