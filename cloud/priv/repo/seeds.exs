# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     EdgeOsCloud.Repo.insert!(%EdgeOsCloud.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

{:ok, _edge} = EdgeOsCloud.Device.create_edge(%{name: "first one", ip: "140.115.50.50", status: true})
{:ok, _edge} = EdgeOsCloud.Device.create_edge(%{name: "second one", ip: "1.1.1.1", status: false})
