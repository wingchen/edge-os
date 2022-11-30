defmodule EdgeOsCloud.HashIdHelper do
  defp get_hasher(salt) do
    Hashids.new([
      salt: salt,
      min_len: 10,
    ])
  end

  def encode(id, salt) do
    hasher = get_hasher(salt)
    Hashids.encode(hasher, id)
  end

  def decode(id_str, salt) do
    hasher = get_hasher(salt)
    {:ok, [id]} = Hashids.decode(hasher, id_str)
    id
  end
end
