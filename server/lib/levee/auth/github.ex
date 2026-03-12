defmodule Levee.Auth.GitHub do
  @moduledoc """
  GitHub API client for checking organization team membership.

  Used during OAuth login to verify that a user belongs to one of the
  configured allowed teams before granting access.
  """

  require Logger

  @github_api_base "https://api.github.com"

  @doc """
  Checks if a user is an active member of a specific GitHub team.

  Uses the GitHub API endpoint:
    GET /orgs/{org}/teams/{team_slug}/memberships/{username}

  Returns `{:ok, :active}` if the user is an active member,
  `{:ok, :not_member}` if they are not, or `{:error, reason}` on failure.

  Accepts an optional `req_options` keyword for Req configuration (useful for testing).
  """
  def check_team_membership(access_token, username, org, team_slug, opts \\ []) do
    url = "#{@github_api_base}/orgs/#{org}/teams/#{team_slug}/memberships/#{username}"

    req_opts =
      Keyword.merge(
        [
          url: url,
          headers: [
            {"authorization", "Bearer #{access_token}"},
            {"accept", "application/vnd.github+json"},
            {"x-github-api-version", "2022-11-28"}
          ],
          retry: false
        ],
        Keyword.get(opts, :req_options, [])
      )

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"state" => "active"}}} ->
        {:ok, :active}

      {:ok, %Req.Response{status: 200, body: %{"state" => _other}}} ->
        # "pending" state means invited but not yet accepted
        {:ok, :not_member}

      {:ok, %Req.Response{status: 404}} ->
        {:ok, :not_member}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(
          "GitHub team membership check returned unexpected status #{status}: #{inspect(body)}"
        )

        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.error("GitHub team membership API call failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Checks if a user is an active member of any of the given teams.

  Returns `:ok` if the user belongs to at least one team, or `:denied` if
  they do not belong to any. Fails closed — any API error results in `:denied`.

  Accepts an optional `req_options` keyword for Req configuration (useful for testing).
  """
  def member_of_any_team?(access_token, username, teams, opts \\ [])
  def member_of_any_team?(_access_token, _username, [], _opts), do: :denied

  def member_of_any_team?(access_token, username, teams, opts) do
    Enum.reduce_while(teams, :denied, fn {org, team_slug}, _acc ->
      case check_team_membership(access_token, username, org, team_slug, opts) do
        {:ok, :active} -> {:halt, :ok}
        _ -> {:cont, :denied}
      end
    end)
  end
end
