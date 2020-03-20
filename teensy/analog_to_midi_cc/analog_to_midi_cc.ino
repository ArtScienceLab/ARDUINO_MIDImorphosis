/*
* This program translates analog inputs to MIDI CC messages according to a predefined protocol. 
* It is tested on a Teensy 3.2
* Note that the Teensy needs to be programmed as MIDI Device for this to work.
*/

// Configuration settings -----------

//Number of analog inputs to use
const int ANALOG_READ_INPUTS = 2;

//interrupt pin for triggering
int interruptPin=A9;

//start taking samples without clock
boolean autostartStamplerTimer = true;

// End configuration settings ----------


//timer for the measurements
IntervalTimer samplerTimer;

//Timer for the heartbeat interval 
// sends note on and off events every second or so
IntervalTimer heartBeatTimer;

//is the heartbeat note currently on or not
boolean heartBeatnoteIsOn = false;

//should we send a heart beat note message?
volatile boolean sendHeartBeatNow = false;

//Should we measure the analog inputs and send the data?
volatile boolean sendMeasurementsNow = false;

volatile boolean interruptInUse = false;
boolean timerInUse = false;

long lastSend = 0;

byte maxWheight=1;
byte prevNote = 0;

//The midi cc clock makes sure that at least one value changes every measurement sample
//This enables a stable sampling even when only value changes are saved as is common in MIDI
const int MIDI_CC_CLOCK_CHANNEL = 15;
const int MIDI_CC_CLOCK_CONTROLLER_NUMBER = 88;

const int DEFAULT_SAMPLE_PERIOD_IN_MICROS = 8333;//or about 120Hz

const int LED_PIN = 13;

int current_midi_cc_clock_value = 64;

void setup() {
  //increase analog read resolution to 13 bits
  analogReadResolution(13);

  //We want to use the internal LED
  pinMode(LED_PIN,OUTPUT);
  
  // Initialize serial port for debug messages
  Serial.begin(115200);

  //every second send a heartbeat note on/off pulse
  heartBeatTimer.begin(toggleSendHeartBeat, 1000000);

  // Use the rising flank on the interrupt pin
  attachInterrupt(interruptPin, toggleSampleAndSendFromPin, RISING); // interrrupt 1 is data ready

  if(autostartStamplerTimer){
    samplerTimer.begin(toggleSampleAndSendFromTimer, DEFAULT_SAMPLE_PERIOD_IN_MICROS);
    timerInUse = true;
     Serial.println("Started sampling with internal clock at 120Hz");
  }else{
     Serial.println("Waiting for clock input or sample rate setting");
  }
 
}

//short interrupt methods
void toggleSendHeartBeat(){
  sendHeartBeatNow = true;
}

void toggleSampleAndSendFromPin(){
  sendMeasurementsNow = true;
  interruptInUse = true;
}

void toggleSampleAndSendFromTimer(){
  sendMeasurementsNow = true;
}


void sendHeartBeat(){
  
  int channel = 15;
  int velocity = millis() - lastSend;
  //limit range to 1-127
  velocity = min(velocity,127);
  velocity = max(1,velocity);

  if(heartBeatnoteIsOn){
    usbMIDI.sendNoteOff(prevNote,0,channel);
    heartBeatnoteIsOn = false;
  }else{
    usbMIDI.sendNoteOn(maxWheight,70,channel);
    heartBeatnoteIsOn=true;
    prevNote = maxWheight;
    maxWheight = 1;
  }
  digitalWrite(LED_PIN,!digitalRead(LED_PIN));
}


void sendAndSample(){
  //first send a midi cc value that always changes
  //this can be used to split messages
  usbMIDI.sendControlChange(MIDI_CC_CLOCK_CONTROLLER_NUMBER, current_midi_cc_clock_value, MIDI_CC_CLOCK_CHANNEL);
  current_midi_cc_clock_value++;
  if(current_midi_cc_clock_value == 128){
    current_midi_cc_clock_value = 0;
  }

  for(int i = 0 ; i < ANALOG_READ_INPUTS ; i++){
    int analogReadIndex = 14+i; // start form port 14
    int index = i;
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

    // For heartbeat
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
  // If requested by the pin or timer, 
  // sample analog pins and send midi data
  if(sendMeasurementsNow){
    sendMeasurementsNow = false;
    sendAndSample();
    lastSend = millis();
  }

  // If requested by the timer, 
  // send a heartbeat pulse
  if(sendHeartBeatNow){
    sendHeartBeatNow = false;

    if(interruptInUse || timerInUse){
      sendHeartBeat();
    }
  }

  // If both timer and pin interrupt are in use
  // give priority to the interrupt and stop the timer
  if(interruptInUse && timerInUse){
    samplerTimer.end();
    timerInUse = false;
  }

  // MIDI Controllers should discard incoming MIDI messages.
  while (usbMIDI.read()) {
    // parse incomming messages
    int type = usbMIDI.getType();
    //0 = Note Off
    //1 = Note On
    //6 = Pitch bend 
    // see here https://www.pjrc.com/teensy/td_midi.html
    if(type==usbMIDI.PitchBend) { 
      setNewSampleRate(usbMIDI.getData1(),usbMIDI.getData2());
    }
    Serial.println(type);
  }
}


void setNewSampleRate(int firstByte,int secondByte){
  int periodInHz = firstByte * 127 + secondByte;
  int periodInMicros = round(1.0 / (periodInHz + 0.0) * 1000000.0);

  Serial.print("Period in micros: ");
  Serial.println(periodInMicros);

  if(timerInUse){
    samplerTimer.end();
  }
    
  samplerTimer.begin(toggleSampleAndSendFromTimer, periodInMicros);
  timerInUse = true;
}
