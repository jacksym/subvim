#!/bin/sh
# usage: fixture.sh DIR  -> creates DIR/repo and DIR/wc (checkout of ^/trunk)
set -e
D=$1; rm -rf "$D"; mkdir -p "$D"; cd "$D"
svnadmin create repo
svn -q mkdir -m layout file://$D/repo/trunk file://$D/repo/branches file://$D/repo/tags
svn -q co file://$D/repo/trunk wc; cd wc
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > a.txt; echo b > b.txt; echo c > c.txt; mkdir d; echo x > d/x.txt
svn -q add a.txt b.txt c.txt d; svn -q ci -m "initial import"
printf 'l1\nl2\nCHANGED3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > a.txt; svn -q ci -m "change line 3"
svn -q up
