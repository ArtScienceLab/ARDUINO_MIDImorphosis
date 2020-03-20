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

	#keep only midi cc_events
	cc_messages = midi_csv.split("\n").reject{|l| l !~ /.+Control_c.+/}

	#split the cc_events
	cc_messages = cc_messages.map do |midi_event|
		midi_msg_data = midi_event.split(",")

		time_in_midi_clocks = midi_msg_data[1].to_i
		channel = midi_msg_data[3].to_i
		cc_number = midi_msg_data[4].to_i
		cc_value = midi_msg_data[5].to_i

		[time_in_midi_clocks,channel,cc_number,cc_value]
	end

	#first pass: decide number of cc_messages (number of sensors)
	#also determine split type 
	cc_numbers_in_file = Hash.new

	cc_messages.each do |midi_event|
		time_in_midi_clocks,channel,cc_number,cc_value = midi_event
		cc_numbers_in_file[cc_number]=cc_value
	end	

	#detect sensors
	cc_number_range = Array.new 
	(102..117).step(2).each do |cc_number|
		if ( cc_numbers_in_file.has_key? cc_number and cc_numbers_in_file.has_key? (cc_number+1))
			cc_number_range << cc_number
			cc_number_range << (cc_number + 1)
		end
	end

	number_of_sensors = cc_number_range.size / 2

	STDERR.puts "Detected #{number_of_sensors} sensors."

	# Detect split type (how to split messages)
	split_via_cc_message = cc_numbers_in_file.has_key? 88

	if (split_via_cc_message)
		STDERR.puts "Will split data via cc message on cc number 88"
	else
		STDERR.puts "Will split data when data for cc message #{cc_number_range[0]} is received"
	end

	csv_file = midi_file.chomp('.mid') + ".csv"
	STDERR.puts "Saving midi events to #{csv_file} "
	data_hash = Hash.new
	previous_time_in_seconds=0

	#this assumes that midi CC messages are sent at the same time 
	timestamp_stored = false
	lines = Array.new
	line = Array.new
	first = true
	data_hash = Hash.new
	prev_data_hash = Hash.new

	cc_messages.each do |midi_event|
		
		time_in_midi_clocks,channel,cc_number,cc_value = midi_event

		if (split_via_cc_message and cc_number == 88)
			#store the current line if there is a current line
			lines << line if line.size > 0

			#start a new line
			line = Array.new
		end

		#split the line if the first sensor appears, this expects that 
		#the order of midi messages is respected
		if (!split_via_cc_message and cc_number == cc_number_range[0])
			#store the current line if there is a current line
			lines << line if line.size > 0

			#start a new line
			line = Array.new
		end

		#if there is currently no data line, start a new line
		if line.size == 0
			prev_data_hash = data_hash
			data_hash = Hash.new

			time_in_seconds = 1/1000000.0 * time_in_midi_clocks / clock_pulses_per_quarter_note * tempo
			line << time_in_seconds
			line << data_hash

			#initialize the data_hash, set each key to -1
			cc_number_range.each{|cc_number| line[1][cc_number] = -1}

			#Base the current values on the previous values (repeated values are ignored in MIDI messages)
			prev_data_hash.keys.each{|cc_number| line[1][cc_number] = prev_data_hash[cc_number]}
		end

		#store the value
		if(cc_number != 88)
			line[1][cc_number] = cc_value
		end	
	end

	File.open(csv_file,"w") do |f|
		lines.each do |line|
			print_line = Array.new
			print_line[0] = "%.6f" % line[0]
			data_hash = line[1]
			cc_number_range.sort.each do |cc_number|
				next unless cc_number % 2 == 0
				if(data_hash[cc_number] == -1 or data_hash[cc_number+1] == -1 )
					puts "ERROR no data for #{cc_number} at #{line[0]}"
					print_line << ""
				else

					msb = data_hash[cc_number]
					lsb = data_hash[cc_number+1]
					#from 14 bits to 13bits (the resolution of the analog read)
					value = (msb * (1<<7) + lsb) / 2
					print_line << value.to_s
				end
			end
			f.puts print_line.join(", ")
		end

		STDERR.puts "Created CSV file with #{lines.size} events"
	end
end