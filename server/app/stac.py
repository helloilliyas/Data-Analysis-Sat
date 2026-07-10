"""Earth Search STAC queries for Sentinel-2 L2A."""

from pystac_client import Client

STAC_URL = "https://earth-search.aws.element84.com/v1"
COLLECTION = "sentinel-2-l2a"


def _client() -> Client:
    return Client.open(STAC_URL)


def search_scenes(polygon: dict, date_range: str, max_cloud: float, limit: int = 100):
    """Scenes intersecting the polygon, newest first.

    Cloud cover here is scene-level (eo:cloud_cover) — a coarse hint for the
    date picker. AOI-level cloud masking happens at processing time.
    """
    search = _client().search(
        collections=[COLLECTION],
        intersects=polygon,
        datetime=date_range,
        query={"eo:cloud_cover": {"lte": max_cloud}},
        sortby=[{"field": "properties.datetime", "direction": "desc"}],
        max_items=limit,
    )
    return list(search.items())


def get_scene(scene_id: str):
    search = _client().search(collections=[COLLECTION], ids=[scene_id], max_items=1)
    items = list(search.items())
    return items[0] if items else None
