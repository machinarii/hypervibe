tell application id "com.microsoft.powerpoint"	if slide state of slide show view of slide show window of active presentation is not slide show state running then
		run slide show slide show settings of active presentation
	else
		exit slide show slide show view of slide show window of active presentation
	end ifend tell