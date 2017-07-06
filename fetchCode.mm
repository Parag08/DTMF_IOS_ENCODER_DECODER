//
//  hello.m
//  hello
//
//  Created by parag on 20/07/15.
//  Copyright (c) 2015 sanjay. All rights reserved.
//

#import "fetchCode.h"


#import "mo_audio.h" //stuff that helps set up low-level audio
#import "FFTHelper.h"
#include "string.h"


CodeCallback callback;

#define SAMPLE_RATE 44100  //22050 //44100
#define FRAMESIZE  512
#define NUMCHANNELS 2
#define kOutputBus 0
#define kInputBus 1

//for isolating frequencies and then avreging and calculating
#define Largenum 1000000000    //For multiplying each avg values so as to get data in readable range
#define NUM_OF_FREQ 8
#define TOLERANCEFACTOR 1     //for distinguishing noises from peaks (Increase to decrease the distance and increase the reliability)
#define CODELEN 5

static int codebuffer[CODELEN*4];
static char codeStr[CODELEN+1];
static int codeindex=0;
static double Timer= 0;
static BOOL errorflag = false;
static BOOL doPredective = false;
static BOOL doneflag = false;

double starttimer = 0;


/// Nyquist Maximum Frequency
const Float32 NyquistMaxFreq = SAMPLE_RATE/2.0;

/// caculates HZ value for specified index from a FFT bins vector
Float32 frequencyHerzValue(long frequencyIndex, long fftVectorSize, Float32 nyquistFrequency ) {
    return ((Float32)frequencyIndex/(Float32)fftVectorSize) * nyquistFrequency;
}

// caculates the index value for a given frequencies
Float32 frequencyIndexValue(int frequency, long fftVectorSize, Float32 nyquistFrequency ) {
    return ((Float32)frequency*(Float32)fftVectorSize) /nyquistFrequency;
}

// The Main FFT Helper
FFTHelperRef *fftConverter = NULL;



//Accumulator Buffer=====================

const UInt32 accumulatorDataLenght = 2048;  //16384; //32768; 65536; 131072;   For calculating the detection window divide this window by 44.1 i.e. 2048/44.1 = 43 ms
UInt32 accumulatorFillIndex = 0;
Float32 *dataAccumulator = nil;
static void initializeAccumulator() {
    dataAccumulator = (Float32*) malloc(sizeof(Float32)*accumulatorDataLenght);
    accumulatorFillIndex = 0;
}
static void destroyAccumulator() {
    if (dataAccumulator!=NULL) {
        free(dataAccumulator);
        dataAccumulator = NULL;
    }
    accumulatorFillIndex = 0;
}

static BOOL accumulateFrames(Float32 *frames, UInt32 lenght) { //returned YES if full, NO otherwise.
    //    float zero = 0.0;
    //    vDSP_vsmul(frames, 1, &zero, frames, 1, lenght);
    
    if (accumulatorFillIndex>=accumulatorDataLenght) { return YES; } else {
        memmove(dataAccumulator+accumulatorFillIndex, frames, sizeof(Float32)*lenght);
        accumulatorFillIndex = accumulatorFillIndex+lenght;
        if (accumulatorFillIndex>=accumulatorDataLenght) { return YES; }
    }
    return NO;
}

static void emptyAccumulator() {
    accumulatorFillIndex = 0;
    memset(dataAccumulator, 0, sizeof(Float32)*accumulatorDataLenght);
}
//=======================================


//==========================Window Buffer
const UInt32 windowLength = accumulatorDataLenght;
Float32 *windowBuffer= NULL;
//=======================================


//round of the maximum frequency to its nearest trasmission frequency
static int roundOfFrequencies(int frequency)
{
    int remainder = frequency%200;
    if(remainder > 100)
    {
        frequency = frequency + (200-remainder);
    }
    else
    {
        frequency = frequency - remainder;
    }
    return frequency;
}


//Decoder: generate the number back from the maximum frequencies
static int getNumberFromFrequencies(int frequencyOne,int frequencyTwo)
{
    frequencyOne = roundOfFrequencies(frequencyOne);
    frequencyTwo = roundOfFrequencies(frequencyTwo);
    int mentisa = (frequencyOne - 18000)/200;
    int exponent = (frequencyTwo - 18000)/200;
    int number = mentisa + (exponent-4)*4;              //of the form a+4^b
    return number;
}

//Save code in the final array after reciving the end of the code in case of no errors
static void generateCode()
{
    if(errorflag==false&&codeindex==CODELEN+2)
    {
        printf("\ngetcodeCalled\n");
        for (int i = 0; i<=CODELEN; i++) {
            
            if(codebuffer[i+1]<10)
            {
                codeStr[i] = codebuffer[i+1] + '0';
            }
            else
            {
                switch (codebuffer[i+1]) {
                    case 10:
                        codeStr[i] ='A';
                        break;
                    case 11:
                        codeStr[i] = 'B';
                        break;
                    case 12:
                        codeStr[i] = 'C';
                        break;
                    case 13:
                        codeStr[i] = 'D';
                        break;
                    default:
                        codeStr[i] = NULL;
                        break;
                }
            }
            printf("[%d]=[%d]",codeStr[i],codebuffer[i+1]);
        }
        codeStr[CODELEN] = NULL;
        doneflag = true;
    }
    codeindex = 0;
    errorflag = false;    //in case it was set to true
}

//
static void pushNumberInCode(int dtmfCode){
    printf("code = %d\n",dtmfCode);
    static int count = 0;
    static BOOL istrue = false;
    static int last = -1 , previoulast = -1;
    static int seqEnd = -1;
    if(dtmfCode ==  14 || istrue)
    {
        istrue = true;
        if(count == 0)
        {
            last = dtmfCode;
        }else if(count == 1)
        {
            previoulast = dtmfCode;
        }else if(count == 2){
            if(last == previoulast){
                seqEnd = last;
                codebuffer[codeindex] = seqEnd;
                if(seqEnd == -2){
                    seqEnd=dtmfCode;
                    codebuffer[codeindex] = seqEnd;
                }
            }else if(last == dtmfCode){
                seqEnd = last;
                codebuffer[codeindex] = seqEnd;
                if(seqEnd == -2){
                    seqEnd=previoulast;
                    codebuffer[codeindex] = seqEnd;
                }
                
            }else if(previoulast == dtmfCode)
            {
                seqEnd = previoulast;
                codebuffer[codeindex] = seqEnd;
                if(seqEnd == -2){
                    seqEnd=last;
                    codebuffer[codeindex] = seqEnd;
                }
                
            }else{
                if(doPredective){
                    if(last == -2)
                    {
                        seqEnd = previoulast;
                    }
                    else if(previoulast == -2)
                    {
                        seqEnd = dtmfCode;
                    }
                    else if(dtmfCode == -2)
                    {
                        seqEnd = previoulast;
                    }
                    codebuffer[codeindex] = seqEnd;
                }
                else
                {
                    errorflag = true;
                    printf("error [%d,%d %d]",last,previoulast,dtmfCode);}
                
            }
            if(seqEnd == -2)
            {
                errorflag = true;
                printf("error [%d,%d %d]",last,previoulast,dtmfCode);}
            
            printf("seqend=%d\n",seqEnd);
            codeindex++;
        }
        if(seqEnd == 15){
            istrue = false;
            seqEnd = -1;
            generateCode();
        }
        if(count ==2){
            count =0;
            last = -1;
            previoulast =-1;
        }else
            count++;
        
    }
}


int maxFrequecyOne(Float32 *vector,unsigned long size)
{
    int start = frequencyIndexValue(17900, size , NyquistMaxFreq);
    int end = frequencyIndexValue(18700, size , NyquistMaxFreq);
    int maxfrequency = 0;
    Float32 maxfrequencypitch = 0.0;
    Float32 avgIntheband = 0.0;
    for (int i=start; i<end; i++) {
        if(maxfrequencypitch<vector[i]*Largenum)
        {
            maxfrequencypitch = vector[i]*Largenum;
            maxfrequency = i;
        }
        avgIntheband = avgIntheband + vector[i]*Largenum;
        
    }
    avgIntheband = avgIntheband/(end-start);
    maxfrequency = frequencyHerzValue(maxfrequency, size, NyquistMaxFreq);
    if((maxfrequencypitch>avgIntheband*5)&&(maxfrequencypitch>TOLERANCEFACTOR))
    {
        return maxfrequency;
    }
    else
    {
        return -1;
    }
}

int maxFrequecyTwo(Float32 *vector,unsigned long size)
{
    int start = frequencyIndexValue(18700, size , NyquistMaxFreq);
    int end = frequencyIndexValue(19500, size , NyquistMaxFreq);
    
    int maxfrequency = 0;
    Float32 maxfrequencypitch = 0.0;
    Float32 avgIntheband = 0.0;
    for (int i=start; i<end; i++) {
        if(maxfrequencypitch<vector[i]*Largenum)
        {
            maxfrequencypitch = vector[i]*Largenum;
            maxfrequency = i;
        }
        avgIntheband = avgIntheband + vector[i]*Largenum;
        
    }
    avgIntheband = avgIntheband/(end-start);
    maxfrequency = frequencyHerzValue(maxfrequency, size, NyquistMaxFreq);
    if((maxfrequencypitch>avgIntheband*5)&&(maxfrequencypitch>TOLERANCEFACTOR))
    {
        return maxfrequency;
    }
    else
    {
        return -1;
    }
}

static void findMaxfrequency(Float32 *vector,unsigned long size){
    @try {
        int maxfrequecyone = maxFrequecyOne(vector,size);
        int maxfrequecytwo = maxFrequecyTwo(vector,size);
        if((maxfrequecyone!=-1)&&(maxfrequecytwo!=-1)){
            int number = getNumberFromFrequencies(maxfrequecyone,maxfrequecytwo);
            pushNumberInCode(number);
        }
        else
        {
            pushNumberInCode(-2);
        }
    }
    @catch (NSException *exception) {
        
    }
}



static void ComputeFFtandgetCode(Float32 *buffer, FFTHelperRef *fftHelper, UInt32 frameSize, Float32 *freqValue) {
    Float32 *fftData = computeFFT(fftHelper, buffer, frameSize);
    fftData[0] = 0.0;
    unsigned long length = frameSize/2.0;
    findMaxfrequency(fftData, length);
}







#pragma mark MAIN CALLBACK
void AudioCallback( Float32 * buffer, UInt32 frameSize, void * userData )
{
    double endtime;
    endtime = [[NSDate date] timeIntervalSince1970];
    printf("endtime = %f starttime = %f",starttimer,endtime);
    if((endtime - starttimer <= Timer)&&(!doneflag))
    {
        //take only data from 1 channel
        Float32 zero = 0.0;
        vDSP_vsadd(buffer, 2, &zero, buffer, 1, frameSize*NUMCHANNELS);
        
        
        
        if (accumulateFrames(buffer, frameSize)==YES) { //if full
            //printf("|%f|\n",[[NSDate date] timeIntervalSince1970]);
            //windowing the time domain data before FFT (using Blackman Window)
            if (windowBuffer==NULL) { windowBuffer = (Float32*) malloc(sizeof(Float32)*windowLength); }
            vDSP_blkman_window(windowBuffer, windowLength, 0);
            vDSP_vmul(dataAccumulator, 1, windowBuffer, 1, dataAccumulator, 1, accumulatorDataLenght);
            //=========================================
            
            Float32 maxHZValue = 0.0;
            ComputeFFtandgetCode(dataAccumulator, fftConverter, accumulatorDataLenght, &maxHZValue);
            
            //NSLog(@" max HZ = ");
            
            
            
            emptyAccumulator(); //empty the accumulator when finished
        }
        
        memset(buffer, 0, sizeof(Float32)*frameSize*NUMCHANNELS);
        
    }
    else
    {
        
        MoAudio::stop();
        if(doneflag)
        {
            callback(codeStr);
        }
        else
        {
            callback(NULL);
        }
        doneflag = false;
    }
}



@implementation hello

- (void)printHelloworld{
    NSLog(@"Hello, World! \n");
}


- (void)fetchLocationCode:(CodeCallback)intialisecallback :(float)counter{
    memset(codeStr, 0, CODELEN+1);
    Timer = counter;
    doneflag = false;
    starttimer = [[NSDate date] timeIntervalSince1970];
    codeindex = 0;
    [self initMomuAudio];
    callback = intialisecallback;
}

-(void) initMomuAudio {
    fftConverter = FFTHelperCreate(accumulatorDataLenght);
    initializeAccumulator();
    bool result = false;
    static bool isinit  = false;
    if(!isinit){
        isinit = true;
        result = MoAudio::init( SAMPLE_RATE, FRAMESIZE, NUMCHANNELS, false);
        if (!result) { NSLog(@" MoAudio init ERROR"); }
    }
    result = MoAudio::start( AudioCallback, NULL );
    if (!result) { NSLog(@" MoAudio start ERROR"); }
}






@end


