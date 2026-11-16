"""Creates the orb dashboard in New Relic, or updates it when one with its name exists. New Relic finds a new
dashboard by name about a minute after it is made, so run it again only after that.

    ~/miniconda3/envs/orb/bin/python scripts/newrelic_dashboard.py

It reads NEW_RELIC_USER_API_KEY (a User key, NRAK-...) and NEW_RELIC_ACCOUNT_ID from the environment or the repo .env,
and the dashboard from docs/observability/orb-dashboard.json. It prints the dashboard's link, never the key.
"""
from __future__ import annotations

import json
import sys

import httpx

from orb_core.config import env, load_env_prefixes, repo_root

API = "https://api.newrelic.com/graphql"
SPEC = repo_root() / "docs" / "observability" / "orb-dashboard.json"


def graphql(key: str, query: str, variables: dict) -> dict:
    try:
        r = httpx.post(API, headers={"API-Key": key}, json={"query": query, "variables": variables}, timeout=60)
        r.raise_for_status()
    except httpx.HTTPError as e:
        sys.exit(f"New Relic could not be reached or refused the key: {e}")
    body = r.json()
    if body.get("errors"):
        sys.exit(f"New Relic refused the request: {[e.get('message') for e in body['errors']]}")
    return body["data"]


def dashboard(spec: dict, account: int) -> dict:
    return {"name": spec["name"], "description": spec["description"], "permissions": spec["permissions"],
            "pages": [{"name": page["name"], "widgets": [
                {"title": w["title"], "layout": w["layout"], "visualization": {"id": w["viz"]},
                 "rawConfiguration": {"nrqlQueries": [{"accountIds": [account], "query": w["query"]}]}}
                for w in page["widgets"]]} for page in spec["pages"]]}


def main() -> None:
    load_env_prefixes(("NEW_RELIC_",))
    key, account = env("NEW_RELIC_USER_API_KEY", required=True), int(env("NEW_RELIC_ACCOUNT_ID", required=True))
    spec = json.loads(SPEC.read_text())
    found = graphql(key, "query($q: String!) { actor { entitySearch(query: $q) { results { entities { guid } } } } }",
                    {"q": f"name = '{spec['name']}' AND type = 'DASHBOARD' AND accountId = {account}"})
    entities = found["actor"]["entitySearch"]["results"]["entities"]
    if len(entities) > 1:
        sys.exit("More than one dashboard has this name; delete the extra ones (New Relic indexes a change in about a "
                 "minute): " + " ".join(f"https://one.newrelic.com/redirect/entity/{e['guid']}" for e in entities))
    board = dashboard(spec, account)
    if entities:
        data = graphql(key, "mutation($g: EntityGuid!, $d: DashboardInput!) { dashboardUpdate(guid: $g, dashboard: $d) "
                            "{ entityResult { guid } errors { description } } }", {"g": entities[0]["guid"], "d": board})
        result = data["dashboardUpdate"]
    else:
        data = graphql(key, "mutation($a: Int!, $d: DashboardInput!) { dashboardCreate(accountId: $a, dashboard: $d) "
                            "{ entityResult { guid } errors { description } } }", {"a": account, "d": board})
        result = data["dashboardCreate"]
    if result["errors"]:
        sys.exit(f"New Relic refused the dashboard: {[e['description'] for e in result['errors']]}")
    print(("updated" if entities else "created"),
          f"https://one.newrelic.com/redirect/entity/{result['entityResult']['guid']}")


if __name__ == "__main__":
    main()
