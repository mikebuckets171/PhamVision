#!/usr/bin/env python3
"""Writes the Sparkle update feed (appcast.xml) for one release.

usage: make-appcast.py VERSION ZIP_URL "SIGN_UPDATE_OUTPUT" > appcast.xml

SIGN_UPDATE_OUTPUT is what Sparkle's sign_update prints for the zip:
  sparkle:edSignature="..." length="..."
The release notes shown in the update window come from that version's
section of CHANGELOG.md.
"""
import email.utils
import html
import pathlib
import re
import sys

version, url, signed = sys.argv[1], sys.argv[2], sys.argv[3]
m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', signed)
if not m:
    sys.exit("make-appcast: couldn't find the signature and length in: " + signed)
signature, length = m.group(1), m.group(2)

changelog = (pathlib.Path(__file__).parent.parent / "CHANGELOG.md").read_text()
section = re.search(rf"^## {re.escape(version)}\n(.*?)(?=^## |\Z)", changelog, re.S | re.M)
lines = section.group(1).strip().splitlines() if section else []


def inline(text):
    text = html.escape(text)
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)


notes, in_list = [], False
for line in lines:
    if line.startswith("- "):
        if not in_list:
            notes.append("<ul>")
            in_list = True
        notes.append(f"<li>{inline(line[2:])}</li>")
    elif line.strip():
        if in_list:
            notes.append("</ul>")
            in_list = False
        notes.append(f"<p>{inline(line)}</p>")
if in_list:
    notes.append("</ul>")
body = "\n".join(notes) or f"<p>PhamVision {html.escape(version)}</p>"

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PhamVision</title>
    <item>
      <title>PhamVision {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
<style>body {{ font: -apple-system-body; }} li {{ margin-bottom: 4px; }}</style>
{body}
      ]]></description>
      <enclosure url="{html.escape(url)}" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>""")
