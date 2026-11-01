# tests/test_xmlparse.mojo — resources.xmlparse entity + encoding behavior.
# Run: pixi run mojo -I . tests/test_xmlparse.mojo
#
# Plex serializes apostrophes/quotes inside titles and attribute values as
# NUMERIC character references (&#39;, &#x27;) — decoding only the five
# named entities rendered "So I&#39;m a Spider". These tests pin attribute
# decoding (each doc's root is the element carrying the attributes).

from std.testing import assert_equal

from resources.xmlparse import parse_xml, XmlElement


def _attr_of(doc: String, attr: String) raises -> String:
    """Parse a one-element doc and return that element's attribute."""
    var root = parse_xml(doc)
    return String(root.attrs.get(attr, "MISSING"))


def test_numeric_entities() raises:
    """&#39; (decimal) and &#x27; (hex) decode to apostrophes."""
    var doc = String(
        '<Metadata title="So I&#39;m a Spider, So What?, Vol. 03" '
        'summary="&#x27;quoted&#x27;" />'
    )
    assert_equal(_attr_of(doc, "title"), "So I'm a Spider, So What?, Vol. 03")
    assert_equal(_attr_of(doc, "summary"), "'quoted'")


def test_named_entities() raises:
    """The five predefined entities decode (amp covers & in titles)."""
    var doc = String('<Metadata title="AC/DC &amp; &lt; &gt; &quot; &apos;" />')
    assert_equal(_attr_of(doc, "title"), "AC/DC & < > \" '")


def test_unknown_and_malformed_lenient() raises:
    """Unknown/malformed entities pass through as literal text (ET's
    leniency); a stray ampersand never raises."""
    var doc = String(
        '<Metadata a="&nope;" b="&#;" c="&#zz;" d="bare & text" />'
    )
    assert_equal(_attr_of(doc, "a"), "&nope;")
    assert_equal(_attr_of(doc, "b"), "&#;")
    assert_equal(_attr_of(doc, "c"), "&#zz;")
    assert_equal(_attr_of(doc, "d"), "bare & text")


def test_numeric_range_checks() raises:
    """Out-of-range and surrogate refs stay literal; astral ones decode."""
    var doc = String('<Metadata a="&#1114112;" b="&#xD800;" c="&#x1F600;" />')
    assert_equal(_attr_of(doc, "a"), "&#1114112;")
    assert_equal(_attr_of(doc, "b"), "&#xD800;")
    var decoded = _attr_of(doc, "c")
    assert_equal(decoded.count_codepoints(), 1)


def test_unicode_titles() raises:
    """Multi-byte titles survive alongside entity decoding."""
    var doc = String('<Metadata title="Björns Låtar &#39;97" />')
    assert_equal(_attr_of(doc, "title"), "Björns Låtar '97")


def test_uppercase_hex() raises:
    """&#X41; (uppercase-X hex form) decodes."""
    var doc = String('<Metadata a="&#X41;" />')
    assert_equal(_attr_of(doc, "a"), "A")


def test_children_tags_unaffected() raises:
    """Element/child structure parsing is untouched by the entity change."""
    var doc = String(
        '<MediaContainer friendlyName="Yggdrasil">'
        '<Directory ratingKey="40551" title="Tea Shop&#39;s End" />'
        '<Directory ratingKey="97531" title="B" />'
        "</MediaContainer>"
    )
    var root = parse_xml(doc)
    assert_equal(String(root.attrs.get("friendlyName", "")), "Yggdrasil")
    assert_equal(len(root.children), 2)
    assert_equal(String(root.children[0].tag), "Directory")
    assert_equal(
        String(root.children[0].attrs.get("title", "")), "Tea Shop's End"
    )


def main() raises:
    test_numeric_entities()
    print("numeric ok")
    test_named_entities()
    test_unknown_and_malformed_lenient()
    test_numeric_range_checks()
    test_unicode_titles()
    test_uppercase_hex()
    test_children_tags_unaffected()
    print("All xmlparse entity tests passed.")
