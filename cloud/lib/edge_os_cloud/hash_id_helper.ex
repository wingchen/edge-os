defmodule EdgeOsCloud.HashIdHelper do
  require Logger

  defp get_hasher(salt) do
    Hashids.new([
      salt: salt,
      min_len: 25,
    ])
  end

  def encode(id, salt) do
    Logger.debug("encoding #{id} with salt #{salt}")
    hasher = get_hasher(salt)
    Hashids.encode(hasher, id)
  end

  def decode(id_str, salt) do
    Logger.debug("decoding #{id_str} with salt #{salt}")
    hasher = get_hasher(salt)
    {:ok, [id]} = Hashids.decode(hasher, id_str)
    id
  end
end
