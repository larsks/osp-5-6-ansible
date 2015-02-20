#!/bin/sh

awk '
	/^# ?/ {
		gsub(/^# ?/, "", $0)
		print
		last_was_doc=1
		next
	}

	!/^# ?/ && last_was_doc==1 {
		printf "\n\n<!-- break -->\n\n"
		last_was_doc=0
	}

	!/^# / {
		printf "    %s\n", $0
		last_was_doc=0
	}
' $1
