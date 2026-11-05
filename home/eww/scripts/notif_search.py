"""Query parsing and matching for the eww notif-center search leaf."""
import os

FOCUS_WORDS = {"vol": "vol", "volume": "vol", "bright": "bright", "brightness": "bright"}


def parse_query(text):
    q = {"terms": [], "urgent": False, "app": "", "focus": ""}
    for w in text.lower().split():
        if w.startswith("!"):
            q["urgent"] = True
            w = w[1:]
            if not w:
                continue
        if w.startswith("@") and len(w) > 1:
            q["app"] = w[1:]
        else:
            q["terms"].append(w)
    if len(q["terms"]) == 1 and q["terms"][0] in FOCUS_WORDS:
        q["focus"] = FOCUS_WORDS[q["terms"][0]]
    return q


def item_matches(item, q):
    if q["urgent"] and item["urgency"] != "critical":
        return False
    if q["app"] and q["app"] not in item["app"].lower():
        return False
    hay = f'{item["app"]} {item["summary"]} {item["body"]}'.lower()
    return all(t in hay for t in q["terms"])


def row_matches(label, q):
    if q["urgent"] or q["app"]:
        return False
    return all(t in label.lower() for t in q["terms"])


def annotate_groups(groups, q):
    out = []
    for g in groups:
        items = [{**i, "match": item_matches(i, q)} for i in g["items"]]
        out.append({**g, "items": items, "match": any(i["match"] for i in items)})
    return out


def query_path():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "notif-query")


def read_query():
    try:
        with open(query_path()) as f:
            return f.read().strip()
    except OSError:
        return ""


def write_query(text):
    tmp = query_path() + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, query_path())
