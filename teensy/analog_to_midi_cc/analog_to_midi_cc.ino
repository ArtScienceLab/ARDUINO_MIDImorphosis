/*
* This program translates analog inputs to MIDI CC messages according to a predefined protocol. 
* It is tested on a Teensy 3.2
* Note that the Teensy needs to be programmed as MIDI Device for this to work.
*
*/

#include <EEPROM.h>

// Configuration settings -----------

//Number of analog inputs to use
const int ANALOG_READ_INPUTS = 8;

//interrupt pin for triggering
int interruptPin=A8;

//pin A9 is used for the coupled  board

//print debug information
boolean debug = false;

// Use an inernal clock or external clock input
boolean internalClock = false;

// End configuration settings ----------

//timer for the measurements
IntervalTimer myTimer;

//Timer for the heartbeat interval 
// sends note on and off events every second or so
IntervalTimer heartBeatTimer;

//is the heartbeat note on or not
volatile boolean noteIsOn = false;

volatile long lastSend = 0;

volatile byte maxWheight=1;
volatile byte prevNote = 0;

static const int INTERNAL_CLOCK_PERIOD = 8333; //in microseconds, 1 / (8333 microseconds) = 120.0048 hertz

//map to remap analog inputs to channels
//e.g A0 to 1 and A1 to 0
int redirectMap[ANALOG_READ_INPUTS];

void setup() {
  //increase analog read resolution to 13 bits
  analogReadResolution(13);
  
  // Initialize serial port
  Serial.begin(115200);

  // Initialize redirect map
  for(int i = 0;i<ANALOG_READ_INPUTS;i++){
    redirectMap[i] = i;
  }

  //every second send a heartbeat note on/off pulse
  heartBeatTimer.begin(sendHeartBeat, 1000000);
  
  if(internalClock){
    // Use the configured period and start the timer
    myTimer.begin(sampleAndSend, INTERNAL_CLOCK_PERIOD);
  }else{
    // Use the rising flank on the interrupt pin
    attachInterrupt(interruptPin, sampleAndSend, RISING); // interrrupt 1 is data ready
  }
}

void sendHeartBeat(){
  int channel = 15;
  int velocity = millis() - lastSend;
  //limit range to 1-127
  velocity = min(velocity,127);
  velocity = max(1,velocity);

  if(noteIsOn){
    usbMIDI.sendNoteOff(prevNote,0,channel);
    noteIsOn = false;
  }else{
    usbMIDI.sendNoteOn(maxWheight,70,channel);
    noteIsOn=true;
    prevNote = maxWheight;
    maxWheight = 1;
  }
}

void sampleAndSend(){
  cli();
  sendAndSample();
  lastSend = millis();
  sei();
}

void sendAndSample(){

  for(int i = 0 ; i < ANALOG_READ_INPUTS ; i++){
    int analogReadIndex = 14+i; // start form port 14
    int index = redirectMap[i];
    int channel = 1 + index; //start from channel 1 
    int cc_controller_msb = 102+index*2; // 102 to 119 controllers are undefined
    int cc_controller_lsb = cc_controller_msb + 1; //least significant 7 bits
    
    // see here for cc controller list http://nickfever.com/music/midi-cc-list
    sendAndSampleSingle(analogReadIndex,channel,cc_controller_msb,cc_controller_lsb);
  }

  usbMIDI.send_now();
}

void sendAndSampleSingle(int analogReadIndex,int channel,int cc_controller_msb,int cc_controller_lsb){
    
    int value = analogRead(analogReadIndex); 
    value = value << 1;// 13 bits to 14 bits multiply by two

    byte wheightInByte = value >> 7;//to 7 bits (0-128)
    maxWheight = max(maxWheight,wheightInByte);

    //msb and lsb
    int msb = value >> 7;
    int lsb = (value - (msb << 7));

    //send two messages, msb first then lsb
    usbMIDI.sendControlChange(cc_controller_msb, msb, channel);
    usbMIDI.sendControlChange(cc_controller_lsb, lsb, channel);
}

void loop() {
  // MIDI Controllers should discard incoming MIDI messages.
  while (usbMIDI.read()) {
    // parse incomming messages
    int type = usbMIDI.getType();
    //0 = Note Off
    //1 = Note On
    //6 = Pitch bend 
    // see here https://www.pjrc.com/teensy/td_midi.html
    if(type==1) { //0x90
      setNewSampleRate(usbMIDI.getData1(),usbMIDI.getData2());
    }else if (type==0) { //0x80
      setNewMapping(usbMIDI.getData1(),usbMIDI.getData2());
    } else if (type==6){ //0xE0
      setTrigger(usbMIDI.getData1(),usbMIDI.getData2());
    }
  }
}

void setNewSampleRate(int firstByte,int secondByte){
    int periodInHz = firstByte * 127 + secondByte;
    int periodInMicros = round(1.0 / (periodInHz + 0.0) * 1000000.0);
    if(debug){
      Serial.print("Period in micros: ");
      Serial.println(periodInMicros);
    }
    myTimer.end();
    myTimer.begin(sampleAndSend, periodInMicros);
}

void setTrigger(int port,int enable){
  if(enable==1){
    attachInterrupt(port, sampleAndSend, RISING);
  }else{
    detachInterrupt(port);
  }
}

void setNewMapping(int index,int redirect){
  redirectMap[index]=redirect;
  Serial.print("Redirect ");
  Serial.print(index);
  Serial.print(" to: ");
  Serial.println(redirect);
  EEPROM.write(index,redirect);
}

