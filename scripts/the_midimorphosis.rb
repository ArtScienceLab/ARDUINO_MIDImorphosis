#!/usr/bin/env ruby

#converts note on messages in a midi file to 
#it needs the midicsv tool http://www.fourmilab.ch/webtools/midicsv/

midi_bpm = ARGV[0]

if (midi_bpm.to_i < 40 or midi_bpm.to_i > 350)
	STDERR.puts "Expecting a reasonable BPM value as first argument: got #{midi_bpm}"
	exit(-7)
end

show_presision = ARGV[1] == "-p"


midi_file = Array.new

if(show_presision)
	#all other args are midi files
	midi_files = ARGV.slice(2..-1).map{|f| File.expand_path(f)}
else
	#all other args are midi files
	midi_files = ARGV.slice(1..-1).map{|f| File.expand_path(f)}
end


midi_files.each do |midi_file|

	STDERR.puts "Processing #{midi_file} ..."

	midi_csv = `midicsv '#{midi_file}'`

	# Track, Time, Tempo, Number
	# The tempo is specified as the Number of microseconds per quarter note, between 1 and 16777215. 
	# A value of 500000 corresponds to 120 quarter notes (“beats”) per minute. 
	# To convert beats per minute to a Tempo value, take the quotient from dividing 
	# 60,000,000 by the beats per minute.
	#
	# Example
	#1, 0, Tempo, 500000

	midi_csv =~ /\d+,\s+\d+,\s+Tempo,\s+(\d+)/
	tempo = $1.to_f

	if(tempo==0)
		if midi_bpm
			bpm = midi_bpm.to_f
			STDERR.puts "Did not find tempo. Will use #{midi_bpm} BPM" 
		end
		tempo = 60000000/ bpm
	else
		STDERR.puts "Found a tempo in the MIDI file: #{tempo}"
	end


	#0, 0, Header, format, nTracks, division
	#
	#The first record of a CSV MIDI file is always the Header record.
	#Parameters are format: 
	#  * the MIDI file type (0, 1, or 2), 
	#  * nTracks: the number of tracks in the file, and 
	#  * division: the number of clock pulses per quarter note. 
	#  * The Track and Time fields are always zero.
	#
	# example
	#0, 0, Header, 1, 2, 480
	#0, 0, Header, 0, 1, 96

	midi_csv =~ /\d+,\s+\d+,\s+Header,\s+(\d+),\s+\d+,\s+(\d+)/
	midi_file_type = $1.to_i
	clock_pulses_per_quarter_note = $2.to_f
	#puts clock_pulses_per_quarter_note

	#puts midi_file_type

	#Track, Time, Time_signature, Num, Denom, Click, NotesQ
	#The time signature, metronome click rate, and number of 32nd notes per MIDI quarter note (24 MIDI clock times)
	# are given by the numeric arguments. 
	#  * Num gives the numerator of the time signature as specified on sheet music. 
	#  * Denom specifies the denominator as a negative power of two, for example 2 for a quarter note, 3 for an eighth note, etc. 
	#  * Click gives the number of MIDI clocks per metronome click, and 
	#  * NotesQ the number of 32nd notes in the nominal MIDI quarter note time of 24 clocks (8 for the default MIDI quarter note definition).
	# 1, 0, Time_signature, 4, 2, 36, 8

	# Number of clock pulses per quarter note
	# 120 BPM

	# 120 * 4 * 96 pulses  * 60 pulses/sec

	#Time Absolute time, in terms of MIDI clocks, at which this event occurs. 
	#
	#Track, Time, Note_on_c, Channel, Note, Velocity
	#Send a command to play the specified Note 
	#(Middle C is defined as Note number 60; all other notes are relative in the MIDI specification, 
	#	but most instruments conform to the well-tempered scale) on the given 
	#Channel with Velocity (0 to 127). A Note_on_c event with Velocity zero is equivalent to a Note_off_c.
	#example
	#
	# 2, 2687, Note_on_c, 0, 66, 44

	if(show_presision)
		time_in_seconds = 1/1000000.0  / clock_pulses_per_quarter_note * tempo
		puts "#{File.basename(midi_file)} %.6f milliseconds" % (time_in_seconds * 1000.0) 
		exit
	end

	#else
	csv_file = midi_file.chomp('.mid') + ".csv"
	STDERR.puts "Saving midi events to #{csv_file} ..."
	data_hash = Hash.new
	#CC messages for the 
	cc_number_range = (102..117)

	previous_time_in_seconds=0

	midi_csv.split("\n").reject{|l| l !~ /.+Control_c.+/}.each do |midi_event|
		midi_msg_data = midi_event.split(",")
		time_in_midi_clocks = midi_msg_data[1].to_i
		time_in_seconds = 1/1000000.0 * time_in_midi_clocks / clock_pulses_per_quarter_note * tempo

		unless data_hash[time_in_seconds]
			data_hash[time_in_seconds] = Hash.new
			#initialize each cc value on zero
			if(previous_time_in_seconds !=0)
				cc_number_range.each{|cc_number| data_hash[time_in_seconds][cc_number]= data_hash[previous_time_in_seconds][cc_number]  }
			else
				cc_number_range.each{|cc_number| data_hash[time_in_seconds][cc_number]= 0 }
			end
		end

		previous_time_in_seconds= time_in_seconds

		channel = midi_msg_data[3].to_i
		cc_number = midi_msg_data[4].to_i
		cc_value = midi_msg_data[5].to_i

		data_hash[time_in_seconds][cc_number] = cc_value
	end

	File.open(csv_file,"w") do |f|
		data_hash.keys.sort.each do |time_in_seconds|
			line = Array.new
			line << "%.6f" % time_in_seconds
			cc_number_range.step(2).each do |cc_number|
				msb = data_hash[time_in_seconds][cc_number]
				
				lsb = data_hash[time_in_seconds][cc_number+1]
				#from 14 bits to 13bits (the resolution of the analog read)
				value = (msb * (1<<7) + lsb) / 2
				#line << msb
				#line << lsb
				line << value.to_s
			end
			f.puts line.join(", ")
		end
	end
end