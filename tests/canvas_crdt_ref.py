"""Reference implementation of the canvas CRDT (docs/CANVAS.md), used to prove convergence before porting to Dart
(app/lib/services/canvas_crdt.dart, which must behave identically).

Lists (RGA): the block list, each text block's characters, each table's rows and columns. Element id = (lamport,
site). Insert after a reference element; concurrent inserts at the same place are ordered by id, larger first.
Deletes leave tombstones. Registers (LWW): block type, checked, table cells, title; the larger id wins.
Ops whose reference is not known yet are buffered until it arrives, so any delivery order converges.
"""
import random

def key(i): return (i[0], i[1])          # id = [lamport, site]

class Doc:
    def __init__(self, site):
        self.site, self.clock = site, 0
        self.lists: dict[str, list[dict]] = {}
        self.regs: dict[tuple, tuple] = {}         # (obj, key) -> (id, val)
        self.pending: list[dict] = []
        self.seen: set = set()

    # ---------- applying ----------
    def _has(self, lst, i): return i is None or any(e["id"] == i for e in self.lists.get(lst, []))
    def _ready(self, op):
        if op["op"] == "ins": return self._has(op["list"], op["after"])
        if op["op"] == "del": return all(self._has(op["list"], i) for i in op["ids"])
        return True
    def apply(self, op):
        self.pending.append(op); progress = True
        while progress:
            progress = False
            for o in list(self.pending):
                if self._ready(o):
                    self.pending.remove(o); self._apply(o); progress = True
    def _apply(self, op):
        oid = tuple(op["id"]) if "id" in op else None
        tag = (op["op"], op.get("list") or op.get("obj"), oid, tuple(map(tuple, op.get("ids", []))))
        if tag in self.seen: return                # duplicate delivery is harmless
        self.seen.add(tag)
        if oid: self.clock = max(self.clock, oid[0] + len(op.get("vals", [""])) - 1)
        if op["op"] == "ins":
            lst = self.lists.setdefault(op["list"], [])
            for k, v in enumerate(op["vals"]):
                nid = [op["id"][0] + k, op["id"][1]]
                if any(e["id"] == nid for e in lst): continue      # already have it (e.g. from a snapshot)
                after = op["after"] if k == 0 else [op["id"][0] + k - 1, op["id"][1]]
                pos = 0 if after is None else next(j for j, e in enumerate(lst) if e["id"] == after) + 1
                while pos < len(lst) and key(lst[pos]["id"]) > key(nid): pos += 1
                lst.insert(pos, {"id": nid, "val": v, "del": False})
        elif op["op"] == "del":
            for e in self.lists.get(op["list"], []):
                if e["id"] in op["ids"]: e["del"] = True
        elif op["op"] == "set":
            k = (op["obj"], op["key"]); cur = self.regs.get(k)
            if cur is None or key(op["id"]) > key(cur[0]): self.regs[k] = (op["id"], op["val"])

    # ---------- local edits (return ops to send) ----------
    def _id(self, n=1): i = [self.clock + 1, self.site]; self.clock += n; return i
    def visible(self, lst): return [e for e in self.lists.get(lst, []) if not e["del"]]
    def text(self, lst): return "".join(e["val"] for e in self.visible(lst))
    def insert(self, lst, index, s):
        vis = self.visible(lst); after = vis[index - 1]["id"] if index > 0 else None
        op = {"op": "ins", "list": lst, "after": after, "id": self._id(len(s)), "vals": list(s)}; self._apply(op); return op
    def delete(self, lst, index, n):
        ids = [e["id"] for e in self.visible(lst)[index:index + n]]
        op = {"op": "del", "list": lst, "ids": ids}; self._apply(op); return op
    def set(self, obj, k, v):
        op = {"op": "set", "obj": obj, "key": k, "val": v, "id": self._id()}; self._apply(op); return op
    def state(self):
        return ({l: [(tuple(e["id"]), e["val"], e["del"]) for e in v] for l, v in self.lists.items()},
                {k: v[1] for k, v in self.regs.items()})

def converge_trial(seed, sites=3, ops=60):
    rnd = random.Random(seed); docs = [Doc(f"d{i}") for i in range(sites)]; log = []
    for _ in range(ops):
        d = rnd.choice(docs); L = rnd.choice(["b1:text", "b2:text"]); n = len(d.visible(L))
        r = rnd.random()
        if r < 0.6 or n == 0: op = d.insert(L, rnd.randint(0, n), rnd.choice(["a", "bc", "xyz", "Q"]))
        elif r < 0.85: i = rnd.randrange(n); op = d.delete(L, i, rnd.randint(1, min(3, n - i)))
        else: op = d.set("b1", "checked", rnd.random() < .5)
        log.append((d.site, op))
        if rnd.random() < 0.3:                                    # partial sync: deliver a random subset now
            for x in docs:
                for s, o in rnd.sample(log, min(len(log), 5)):
                    if s != x.site: x.apply(o)
    for x in docs:                                                # finally everything, in a random order, twice
        order = log[:] + log[:]; rnd.shuffle(order)
        for s, o in order:
            if s != x.site: x.apply(o)
    st = [d.state() for d in docs]
    assert all(s == st[0] for s in st), f"seed {seed}: replicas differ"
    assert all(not d.pending for d in docs)
    return docs[0]

def test_two_offline_edits_same_paragraph_both_kept():
    a, b = Doc("A"), Doc("B")
    base = a.insert("p", 0, "The ring is ready"); b.apply(base)
    oa = a.insert("p", 4, "Dubai ")                 # offline on A: "The Dubai ring is ready"
    ob = b.insert("p", 17, " for traffic")          # offline on B: "The ring is ready for traffic"
    a.apply(ob); b.apply(oa)
    assert a.text("p") == b.text("p") == "The Dubai ring is ready for traffic"

def test_concurrent_insert_same_place_same_order():
    a, b = Doc("A"), Doc("B")
    oa = a.insert("p", 0, "X"); ob = b.insert("p", 0, "Y")
    a.apply(ob); b.apply(oa)
    assert a.text("p") == b.text("p") and set(a.text("p")) == {"X", "Y"}

def test_delete_vs_insert_inside():
    a, b = Doc("A"), Doc("B"); base = a.insert("p", 0, "hello world"); b.apply(base)
    da = a.delete("p", 5, 6); ib = b.insert("p", 8, "!!")
    a.apply(ib); b.apply(da)
    assert a.text("p") == b.text("p") == "hello!!"

def test_out_of_order_buffered():
    a, b = Doc("A"), Doc("B"); o1 = a.insert("p", 0, "ab"); o2 = a.insert("p", 2, "cd"); o3 = a.delete("p", 1, 2)
    for o in (o3, o2, o1): b.apply(o)
    assert b.text("p") == a.text("p") == "ad" and not b.pending

def test_register_last_writer_wins_everywhere():
    a, b = Doc("A"), Doc("B"); sa = a.set("b1", "checked", True); sb = b.set("b1", "checked", False)
    a.apply(sb); b.apply(sa); assert a.state()[1] == b.state()[1]

def test_snapshot_then_replay_is_harmless():
    import copy
    a = Doc("A"); ops = [a.insert("p", 0, "abc"), a.insert("p", 3, "def"), a.delete("p", 1, 1)]
    b = copy.deepcopy(a); b.site = "B"; b.seen = set()          # loaded from a snapshot: no record of ops seen
    for o in ops: b.apply(o)
    assert b.text("p") == a.text("p") == "acdef"

def test_random_convergence_500_trials():
    for seed in range(500): converge_trial(seed)

if __name__ == "__main__":
    for n, f in list(globals().items()):
        if n.startswith("test_"): f(); print("PASS", n)
