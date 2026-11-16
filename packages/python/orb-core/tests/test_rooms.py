from orb_core.agent import SESSION_ID
from orb_core.rooms import room_for, session_for


def test_session_for_rooms_of_the_web_page_and_others():
    assert session_for("orb-20261021-191500-a1b2c3") == "20261021-191500-a1b2c3"
    a, b = session_for("Some Room!"), session_for("Some Room!")
    assert a == b and SESSION_ID.match(a) and a.startswith("room-")  # stable and valid
    assert session_for("orb-BAD ID") != "BAD ID"  # an invalid ID after the prefix does not pass


def test_a_session_room_maps_back_to_its_session():
    assert session_for(room_for("20261021-191500-a1b2c3")) == "20261021-191500-a1b2c3"
