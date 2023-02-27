defmodule EdgeOsCloudWeb.InstallController do
  use EdgeOsCloudWeb, :controller
  require Logger

  defp get_team(team_hash) do
    EdgeOsCloud.HashIdHelper.decode(team_hash, EdgeOsCloud.System.get_setting!("id_hash_salt"))
    |> EdgeOsCloud.Accounts.get_team()
  end

  defp team_valid(team_hash) do
    case get_team(team_hash) do
      nil -> false
      team ->
        not team.deleted
    end
  end

  defp installation_constants() do
    """
    EDGE_WORK_DIR=/opt/edge-os-edge
    EDGE_EXE_NAME=edgeos_edge
    EDGE_DOWNLOAD_NAME=edgeos.tar.xz

    EDGE_EXE=$EDGE_WORK_DIR/$EDGE_EXE_NAME
    DOWNLOAD_PATH=/tmp/$EDGE_DOWNLOAD_NAME
    """
  end

  defp download_daemon() do
    """
    DownloadDeamon() {
        HW=$(uname -m)

        case "$HW" in
            "x86_64")
                architecture="x86_64a"
                ;;
            "x86")
                architecture="x86"
                ;;
            "arm"*)
                architecture="arm"
                ;;
            "aarch64"*)
                architecture="armv0"
                ;;

            *)
                echo "Cannot identify the hardware architecture type: $HW, please contact the EdgeOS admin for help."
                exit 1
        esac

        url="https://github.com/wingchen/edge-os/releases/download/0.0.2/edgeos_edge_$architecture.tar.xz"
        echo "downloading daemon from release url: $url"
        wget "$url" -O $DOWNLOAD_PATH || /bin/busybox wget "$url" -O $DOWNLOAD_PATH
    }
    """
  end

  defp extract() do
    """
    Extract() {
        if [ -f $DOWNLOAD_PATH ]; then
            echo "Extracting EdgeOS..."

            mkdir -p $EDGE_WORK_DIR
            chmod 600 $EDGE_WORK_DIR
            rm -f $EDGE_EXE

            cd $EDGE_WORK_DIR
            tar -xf $DOWNLOAD_PATH

            chmod a+x $EDGE_EXE
            rm $DOWNLOAD_PATH
        fi
    }
    """
  end

  def new_edge(conn, %{"team_hash" => team_hash}) do
    if team_valid(team_hash) do
      cloud_url = "https://#{System.get_env("PHX_HOST", "127.0.0.1:4000")}"
      content = """
      #!/bin/sh

      abort()
      {
          echo >&2 '
          *** ERROR - NOT INSTALLED ***
          '
          echo "We are not able to install the edge for you. Exiting..." >&2
          echo "Please contact the system admin for help." >&2
          exit 1
      }

      trap 'abort' 0

      set -e

      CLOUD_URL=#{cloud_url}
      TEAM_HASH=#{team_hash}

      #{installation_constants()}

      SYSTEMD_SERVICE=/etc/systemd/system/

      #{download_daemon()}

      #{extract()}

      InstallSystemdService() {
          url="${CLOUD_URL}/install/${TEAM_HASH}/edgeos.service"
          echo "installing edgeos service from: $url"
          wget "$url" -O /tmp/edgeos.service || /bin/busybox wget "$url" -O /tmp/edgeos.service

          mv /tmp/edgeos.service /etc/systemd/system/edgeos.service
          chmod a+x /etc/systemd/system/edgeos.service
      }

      RunEdgeOS() {
          echo "Starting EdgeOS service..."
          systemctl start edgeos || :
          systemctl restart edgeos || :
          systemctl enable edgeos
      }

      ConfirmOpensshServer() {
        if [ -z "$(which sshd)" ]
        then
          echo ""
          echo "Sshd is required in order to use the Remote Connection & Remote Access features."

          if [ -n "$(which apt-get)" ]
          then
            echo "Installing openssh-server"
            apt-get install -y openssh-server || :

          elif [ -n "$(which apt)" ]; then
            echo "Installing openssh-server"
            apt install -y openssh-server || :

          else
            echo "Please install openssh-server on your edge and try installing edgeos again..."
          fi
        fi
      }

      #### installatoin logic goes here ####
      DownloadDeamon
      Extract
      InstallSystemdService

      echo ""
      RunEdgeOS
      echo ""
      echo "EdgeOS Installed Successfully. It's trying to connect to the cloud. Please check the cloud UI for details."

      ConfirmOpensshServer || :
      trap : 0
      """
      conn
      |> put_status(:ok)
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", "attachment; filename=new_edge.sh")
      |> put_root_layout(false)
      |> send_resp(200, content)
    else
      Logger.error("user is not supposed to work on the team #{team_hash}")
      content = """
      Not able create a valid script for user with team: #{team_hash}
      """

      conn
      |> put_status(:ok)
      |> put_resp_content_type("text/plain")
      |> put_root_layout(false)
      |> send_resp(500, content)
    end
  end

  def update_edge(conn, %{}) do
    content = """
    #!/bin/sh

    #{installation_constants()}

    #{download_daemon()}

    #{extract()}

    RestartEdgeOS() {
        echo "Restarting EdgeOS service..."
        systemctl restart edgeos
    }

    #### update logic goes here ####
    DownloadDeamon
    Extract

    echo ""
    RestartEdgeOS
    echo ""
    echo "EdgeOS Updated Successfully. It's trying to connect to the cloud."
    """
    conn
    |> put_status(:ok)
    |> put_resp_content_type("text/plain")
    |> put_resp_header("content-disposition", "attachment; filename=update_edge.sh")
    |> put_root_layout(false)
    |> send_resp(200, content)
  end

  def edge_service(conn, %{"team_hash" => team_hash}) do
    if team_valid(team_hash) do
      cloud_url = "wss://#{System.get_env("PHX_HOST", "127.0.0.1:4000")}"
      content = """
      [Unit]
      Description=The EdgeOS daemon for users to access their edge from anywhere on the internet
      After=network.target
      StartLimitInterval=0

      [Service]
      Environment=EDGE_OS_EDGE_DIR=/opt/edge-os-edge
      Environment=EDGE_OS_CLOUD_TEAM_HASH=#{team_hash}
      Environment=EDGE_OS_CLOUD_URL=#{cloud_url}
      Restart=always
      RestartSec=3
      ExecStart=/opt/edge-os-edge/edgeos_edge
      User=root
      Group=root

      [Install]
      WantedBy=multi-user.target
      """

      conn
      |> put_status(:ok)
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", "attachment; filename=edgeos.service")
      |> put_root_layout(false)
      |> send_resp(200, content)
    else
      Logger.error("user trying to connect to invalid team: #{team_hash}")

      content = """
      Invalid input: #{team_hash}
      """

      conn
      |> put_status(:ok)
      |> put_resp_content_type("text/plain")
      |> put_root_layout(false)
      |> send_resp(500, content)
    end
  end
end
