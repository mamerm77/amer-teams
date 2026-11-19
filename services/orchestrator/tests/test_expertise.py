from app.expertise import score
def test_ranking():
    assert score("ROADM", ["roadm", "dwdm"]) > score("ROADM", ["cdc-f roadm design"]) > 0
    assert score("coherent 800G", ["800g coherent pluggables"]) > score("coherent 800G", ["ip/mpls"])
    assert score("python", ["optical"]) == 0
