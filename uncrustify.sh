#!/bin/sh

# format source code according to coding style defined in uncrustify.cfg
#
# for more information, see http://uncrustify.sourceforge.net
# and https://github.com/ryanmaxwell/UncrustifyX

cd $(dirname $0)
find osxCalSync -name "*.h" -o -name "*.m" -o -name "*.pch" > uncrustify.input
uncrustify -c uncrustify.cfg --no-backup -l OC -F uncrustify.input
rm uncrustify.input
