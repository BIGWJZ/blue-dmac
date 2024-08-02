import FIFOF::*;
import GetPut :: *;
import Vector::*;

import SemiFifo::*;
import PcieTypes::*;
import DmaTypes::*;
import PcieAxiStreamTypes::*;
import StreamUtils::*;
import PcieDescriptorTypes::*;


typedef 4096                                BUS_BOUNDARY;
typedef TAdd#(1, TLog#(BUS_BOUNDARY))       BUS_BOUNDARY_WIDTH;

typedef Bit#(BUS_BOUNDARY_WIDTH)            PcieTlpMaxMaxPayloadSize;
typedef Bit#(TLog#(BUS_BOUNDARY_WIDTH))     PcieTlpSizeWidth;

typedef 128                                 DEFAULT_TLP_SIZE;
typedef TAdd#(1, TLog#(DEFAULT_TLP_SIZE))   DEFAULT_TLP_SIZE_WIDTH;

typedef 3                                   PCIE_TLP_SIZE_SETTING_WIDTH;
typedef Bit#(PCIE_TLP_SIZE_SETTING_WIDTH)   PcieTlpSizeSetting;      

typedef TAdd#(1, TLog#(TDiv#(BUS_BOUNDARY, BYTE_EN_WIDTH))) DATA_BEATS_WIDTH;
typedef Bit#(DATA_BEATS_WIDTH)                              DataBeats;

typedef PcieAxiStream#(PCIE_REQUESTER_REQUEST_TUSER_WIDTH)  RqAxisStream;

typedef Tuple2#(
    DWordByteEn,
    DWordByteEn
) SideBandByteEn;

typedef struct {
    DmaRequest dmaRequest;
    DmaMemAddr firstChunkLen;
} ChunkRequestFrame deriving(Bits, Eq);                     

interface ChunkCompute;
    interface FifoIn#(DmaRequest)  dmaRequestFifoIn;
    interface FifoOut#(DmaRequest) chunkRequestFifoOut;
    interface Put#(PcieTlpSizeSetting)  setTlpMaxSize;
endinterface 

interface ChunkSplit;
    interface FifoIn#(DataStream)       dataFifoIn;
    interface FifoIn#(DmaRequest)       reqFifoIn;
    interface FifoOut#(DataStream)      chunkDataFifoOut;
    interface FifoOut#(DmaRequest)      chunkReqFifoOut;
    interface Put#(PcieTlpSizeSetting)  setTlpMaxSize;
endinterface

interface ConvertDataStreamsToStraddleAxis;
    interface FifoIn#(DataStream)       dataAFifoIn;
    interface FifoIn#(SideBandByteEn)   byteEnAFifoIn;
    interface FifoIn#(DataStream)       dataBFifoIn;
    interface FifoIn#(SideBandByteEn)   byteEnBFifoIn;
    interface FifoOut#(PcieAxiStream)   axiStreamFifoOut;
endinterface

module mkChunkComputer (TRXDirection direction, ChunkCompute ifc);

    FIFOF#(DmaRequest)   inputFifo  <- mkFIFOF;
    FIFOF#(DmaRequest)   outputFifo <- mkFIFOF;
    FIFOF#(ChunkRequestFrame) splitFifo  <- mkFIFOF;

    Reg#(DmaMemAddr) newChunkPtrReg      <- mkReg(0);
    Reg#(DmaMemAddr) totalLenRemainReg   <- mkReg(0);
    Reg#(Bool)       isSplittingReg      <- mkReg(False);
    
    Reg#(DmaMemAddr)       tlpMaxSize      <- mkReg(fromInteger(valueOf(DEFAULT_TLP_SIZE)));
    Reg#(PcieTlpSizeWidth) tlpMaxSizeWidth <- mkReg(fromInteger(valueOf(DEFAULT_TLP_SIZE_WIDTH)));   

    function Bool hasBoundary(DmaRequest request);
        let highIdx = (request.startAddr + request.length - 1) >> valueOf(BUS_BOUNDARY_WIDTH);
        let lowIdx = request.startAddr >> valueOf(BUS_BOUNDARY_WIDTH);
        return (highIdx > lowIdx);
    endfunction

    function DmaMemAddr getOffset(DmaRequest request);
        // MPS - startAddr % MPS, MPS means MRRS when the module is set to RX mode
        DmaMemAddr remainderOfMps = zeroExtend(PcieTlpMaxMaxPayloadSize'(request.startAddr[tlpMaxSizeWidth-1:0]));
        DmaMemAddr offsetOfMps = tlpMaxSize - remainderOfMps;    
        return offsetOfMps;
    endfunction

    rule getfirstChunkLen;
        let request = inputFifo.first;
        inputFifo.deq;
        let offset = getOffset(request);
        let firstLen = (request.length > tlpMaxSize) ? tlpMaxSize : request.length;
        splitFifo.enq(ChunkRequestFrame {
            dmaRequest: request,
            firstChunkLen: hasBoundary(request) ? offset : firstLen
        });
    endrule

    rule execChunkCompute;
        let splitRequest = splitFifo.first;
        if (isSplittingReg) begin   // !isFirst
            if (totalLenRemainReg <= tlpMaxSize) begin 
                isSplittingReg <= False; 
                outputFifo.enq(DmaRequest {
                    startAddr: newChunkPtrReg,
                    length: totalLenRemainReg
                });
                splitFifo.deq;
                totalLenRemainReg <= 0;
            end 
            else begin
                isSplittingReg <= True;
                outputFifo.enq(DmaRequest {
                    startAddr: newChunkPtrReg,
                    length: tlpMaxSize
                });
                newChunkPtrReg <= newChunkPtrReg + tlpMaxSize;
                totalLenRemainReg <= totalLenRemainReg - tlpMaxSize;
            end
        end 
        else begin   // isFirst
            let remainderLength = splitRequest.dmaRequest.length - splitRequest.firstChunkLen;
            Bool isSplittingNextCycle = (remainderLength > 0);
            isSplittingReg <= isSplittingNextCycle;
            outputFifo.enq(DmaRequest {
                startAddr: splitRequest.dmaRequest.startAddr,
                length: splitRequest.firstChunkLen
            }); 
            if (!isSplittingNextCycle) begin 
                splitFifo.deq; 
            end
            newChunkPtrReg <= splitRequest.dmaRequest.startAddr + splitRequest.firstChunkLen;
            totalLenRemainReg <= remainderLength;
        end
    endrule

    interface  dmaRequestFifoIn = convertFifoToFifoIn(inputFifo);
    interface  chunkRequestFifoOut = convertFifoToFifoOut(outputFifo);

    interface Put setTlpMaxSize;
        method Action put (PcieTlpSizeSetting tlpSizeSetting);
            let setting = tlpSizeSetting;
            setting[valueOf(PCIE_TLP_SIZE_SETTING_WIDTH)-1] = (direction == DMA_TX) ? 0 : setting[valueOf(PCIE_TLP_SIZE_SETTING_WIDTH)-1];
            DmaMemAddr defaultTlpMaxSize = fromInteger(valueOf(DEFAULT_TLP_SIZE));
            tlpMaxSize <= DmaMemAddr'(defaultTlpMaxSize << setting);
            PcieTlpSizeWidth defaultTlpMaxSizeWidth = fromInteger(valueOf(DEFAULT_TLP_SIZE_WIDTH));
            tlpMaxSizeWidth <= PcieTlpSizeWidth'(defaultTlpMaxSizeWidth + zeroExtend(setting));
        endmethod
    endinterface
    
endmodule

// Split the single input DataStream to a list of DataStream chunks
//  - Chunks cannot violate bus boundary requirement
//  - Only the first and the last chunk can be shorter than MaxPayloadSize
//  - Other chunks length must equal to MaxPayloadSize
//  - The module may block the pipeline if one input beat is splited to two beats
module mkChunkSplit(TRXDirection direction, ChunkCompute ifc);
    FIFOF#(DataStream)  dataInFifo       <- mkFIFOF;
    FIFOF#(DmaRequest)  reqInFifo        <- mkFIFOF;
    FIFOF#(DataStream)  chunkOutFifo     <- mkFIFOF;
    FIFOF#(DmaRequest)  reqOutFifo       <- mkFIFOF;
    FIFOF#(DmaRequest)  firstReqPipeFifo <- mkSizedFIFOF(STREAM_SPLIT_LATENCY);
    FIFOF#(DmaRequest)  inputReqPipeFifo <- mkSizedFIFOF(STREAM_SPLIT_LATENCY);

    StreamSplit firstChunkSplitor <- mkStreamSplit;

    Reg#(DmaMemAddr)       tlpMaxSizeReg      <- mkReg(fromInteger(valueOf(DEFAULT_TLP_SIZE)));
    Reg#(PcieTlpSizeWidth) tlpMaxSizeWidthReg <- mkReg(fromInteger(valueOf(DEFAULT_TLP_SIZE_WIDTH)));   
    Reg#(DataBeats)        tlpMaxBeatsReg     <- mkReg(fromInteger(valueOf(TDiv#(DEFAULT_TLP_SIZE, BYTE_EN_WIDTH))));

    Reg#(Bool)      isInProcReg <- mkReg(False);
    Reg#(DataBeats) beatsReg    <- mkReg(0);

    Reg#(DmaMemAddr) nextStartAddrReg <- mkReg(0);
    Reg#(DmaMemAddr) remainLenReg     <- mkReg(0);
    

    function Bool hasBoundary(DmaRequest request);
        let highIdx = (request.startAddr + request.length - 1) >> valueOf(BUS_BOUNDARY_WIDTH);
        let lowIdx = request.startAddr >> valueOf(BUS_BOUNDARY_WIDTH);
        return (highIdx > lowIdx);
    endfunction

    function DmaMemAddr getOffset(DmaRequest request);
        // MPS - startAddr % MPS, MPS means MRRS when the module is set to RX mode
        DmaMemAddr remainderOfMps = zeroExtend(PcieTlpMaxMaxPayloadSize'(request.startAddr[tlpMaxSizeWidthReg-1:0]));
        DmaMemAddr offsetOfMps = tlpMaxSizeReg - remainderOfMps;    
        return offsetOfMps;
    endfunction

    // Pipeline stage 1, calculate the first chunkLen which may be smaller than MPS
    rule getfirstChunkLen;
        // If is the first beat of a new request, get firstChunkLen and pipe into the splitor
        if (!isInProcReg) begin
            let request = reqInFifo.first;
            reqInFifo.deq;
            let stream = dataInFifo.first;
            dataInFifo.deq;
            let offset = getOffset(request);
            let firstLen = (request.length > tlpMaxSizeReg) ? tlpMaxSizeReg : request.length;
            let firstChunkLen = hasBoundary(request) ? offset : firstLen;
            firstChunkSplitor.splitLocationFifoIn.enq(unpack(truncate(firstChunkLen)));
            let firstReq = DmaRequest {
                startAddr : request.startAddr,
                length    : firstChunkLen
            };
            firstReqPipeFifo.enq(firstReq);
            firstChunkSplitor.inputStreamFifoIn.enq(stream);
            inputReqPipeFifo.enq(request);
            isInProcReg <= !stream.isLast;
        end
        // If is the remain beats of the request, continue pipe into the splitor
        else begin
            let stream = dataInFifo.first;
            dataInFifo.deq;
            firstChunkSplitor.inputStreamFifoIn.enq(stream);
            isInProcReg <= !stream.isLast;
        end 
    endrule

    // Pipeline stage 2: use StreamUtils::StreamSplit to split the input datastream to the firstChunk and the remain chunks
    // In StreamUtils::StreamSplit firstChunkSplitor

    // Pipeline stage 3, set isFirst/isLast accroding to MaxPayloadSize, i.e. split the remain chunks
    rule splitToMps;
        let stream = firstChunkSplitor.outputStreamFifoOut.first;
        firstChunkSplitor.outputStreamFifoOut.deq;
        // End of a TLP, reset beatsReg and tag isLast=True
        if (stream.isLast || beatsReg == tlpMaxBeatsReg) begin
            stream.isLast = True;
            beatsReg <= 0;
        end
        else begin
            beatsReg <= beatsReg + 1;
        end
        // Start of a TLP, get Req Infos and tag isFirst=True
        if (beatsReg == 0) begin
            stream.isFirst = True;
            // The first TLP of chunks
            if (firstReqPipeFifo.notEmpty) begin
                let chunkReq = firstReqPipeFifo.first;
                let oriReq = inputReqPipeFifo.first;
                firstReqPipeFifo.deq;
                nextStartAddrReg <= oriReq.startAddr + chunkReq.length;
                remainLenReg     <= oriReq.length - chunkReq.length;
                reqOutFifo.enq(chunkReq);
            end
            // The following chunks
            else begin  
                if (remainLenReg == 0) begin
                    // Do nothing
                end
                else if (remainLenReg <= tlpMaxSizeReg) begin
                    nextStartAddrReg <= 0;
                    remainLenReg     <= 0;
                    let chunkReq = DmaRequest {
                        startAddr: nextStartAddrReg,
                        length   : remainLenReg
                    };
                    reqOutFifo.enq(chunkReq);
                end
                else begin
                    nextStartAddrReg <= nextStartAddrReg + tlpMaxSizeReg;
                    remainLenReg     <= remainLenReg - tlpMaxSizeReg;
                    let chunkReq = DmaRequest {
                        startAddr: nextStartAddrReg,
                        length   : tlpMaxSizeReg
                    };
                    reqOutFifo.enq(chunkReq);
                end
            end
        end
        chunkOutFifo.enq(stream);
    endrule

    interface dataFifoIn = convertFifoToFifoIn(dataInFifo);
    interface reqFifoIn  = convertFifoToFifoIn(reqInFifo);

    interface chunkDataFifoOut = convertFifoToFifoOut(chunkOutFifo);
    interface chunkReqFifoOut  = convertFifoToFifoOut(reqOutFifo);

    interface Put setTlpMaxSize;
        method Action put (PcieTlpSizeSetting tlpSizeSetting);
            let setting = tlpSizeSetting;
            setting[valueOf(PCIE_TLP_SIZE_SETTING_WIDTH)-1] = (direction == DMA_TX) ? 0 : setting[valueOf(PCIE_TLP_SIZE_SETTING_WIDTH)-1];
            DmaMemAddr defaultTlpMaxSize = fromInteger(valueOf(DEFAULT_TLP_SIZE));
            tlpMaxSizeReg <= DmaMemAddr'(defaultTlpMaxSize << setting);
            PcieTlpSizeWidth defaultTlpMaxSizeWidth = fromInteger(valueOf(DEFAULT_TLP_SIZE_WIDTH));
            tlpMaxSizeWidthReg <= PcieTlpSizeWidth'(defaultTlpMaxSizeWidth + zeroExtend(setting));
            // BeatsNum = (MaxPayloadSize + DescriptorSize) / BytesPerBeat
            tlpMaxBeatsReg <= truncate(DmaMemAddr'(defaultTlpMaxSize << setting) >> valueOf(BYTE_EN_WIDTH));
        endmethod
    endinterface
endmodule

typedef 2'b00 NO_TLP_IN_THIS_BEAT;
typedef 2'b01 SINGLE_TLP_IN_THIS_BEAT;
typedef 2'b11 TWO_TLP_IN_THIS_BEAT;

typedef 3 BYTEEN_INFIFO_DEPTH;

// Convert 2 DataStream input to 1 PcieAxiStream output
// - The axistream is in straddle mode which means tKeep and tLast are ignored
// - The core use isSop and isEop to location Tlp and allow 2 Tlp in one beat
// - The input dataStream should be added Descriptor and aligned to DW already
module mkConvertDataStreamsToStraddleAxis(ConvertDataStreamsToStraddleAxis);
    FIFOF#(DataStream)       dataAInFifo <- mkFIFOF;
    FIFOF#(SideBandByteEn)   byteEnAFifo <- mkSizedFIFOF(BYTEEN_INFIFO_DEPTH);
    FIFOF#(DataStream)       dataBInFifo <- mkFIFOF;
    FIFOF#(SideBandByteEn)   byteEnBFifo <- mkSizedFIFOF(BYTEEN_INFIFO_DEPTH);

    FIFOF#(DataBytePtr) dataPrepareAFifo <- mkFIFOF;
    FIFOF#(DataBytePtr) dataPrepareBFifo <- mkFIFOF;

    FIFOF#(PcieAxiStream) axiStreamOutFifo <- mkFIFOF;

    Reg#(StreamWithPtr)  remainStreamAWpReg <- mkRegU;
    Reg#(StreamWithPtr)  remainStreamBWpReg <- mkRegU;

    StreamConcat    streamAconcater <- mkStreamConcat;
    StreamConcat    streamBconcater <- mkStreamConcat;

    Reg#(Bool) isInStreamAReg <- mkReg(False);
    Reg#(Bool) isInStreamBReg <- mkReg(False);
    Reg#(Bool) hasStreamARemainReg <- mkReg(False);
    Reg#(Bool) hasStreamBRemainReg <- mkReg(False);
    Reg#(Bool) hasLastStreamARemainReg <- mkReg(False);
    Reg#(Bool) hasLastStreamBRemainReg <- mkReg(False);

    function PcieRequsterRequestSideBandFrame genRQSideBand(
        PcieTlpCtlIsEopCommon isEop, PcieTlpCtlIsSopCommon isSop, SideBandByteEn byteEnA, SideBandByteEn byteEnB
        );
        let {firstByteEnA, lastByteEnA} = byteEnA;
        let {firstByteEnB, lastByteEnB} = byteEnB;
        let sideBand = PcieRequsterRequestSideBandFrame {
            // Do not use parity check in the core
            parity              : 0,
            // Do not support progress track
            seqNum1             : 0,
            seqNum0             : 0,
            //TODO: Do not support Transaction Processing Hint now, maybe we need TPH for better performance
            tphSteeringTag      : 0,
            tphIndirectTagEn    : 0,
            tphType             : 0,
            tphPresent          : 0,
            // Do not support discontinue
            discontinue         : False,
            // Indicates end of the tlp
            isEop               : isEop,
            // Indicates starts of a new tlp
            isSop               : isSop,
            // Disable when use DWord-aligned Mode
            addrOffset          : 0,
            // Indicates byte enable in the first/last DWord
            lastByteEn          : {pack(lastByteEnB), pack(lastByteEnA)},
            firstByteEn         : {pack(firstByteEnB), pack(firstByteEnA)}
        };
        return sideBand;
    endfunction

    // Pipeline stage 1: get the byte pointer of each stream
    rule prepareBytePtr;
        if (dataInAFifo.notEmpty && dataPrepareAFifo.notFull) begin
            let stream = dataInAFifo.first;
            dataInAFifo.deq;
            let bytePtr = convertByteEn2BytePtr(stream.byteEn);
            dataPrepareAFifo.enq(StreamWithPtr {
                stream : stream,
                bytePtr: bytePtr
            });
        end
        if (dataInBFifo.notEmpty && dataPrepareBFifo.notFull) begin
            let stream = dataInBFifo.first;
            dataInAFifo.deq;
            let bytePtr = convertByteEn2BytePtr(stream.byteEn);
            dataPrepareBFifo.enq(StreamWithPtr {
                stream : stream,
                bytePtr: bytePtr
            });
        end
    endrule

    // Pipeline Stage 2: concat the stream with its remain data (if exist)
    rule genStraddlePcie;
        let straddleWpA = getEmptyStreamWithPtr;
        let straddleWpB = getEmptyStreamWithPtr;
        Data straddleData = 0;
        let isSop = PcieTlpCtlIsSopCommon {
            isSopPtrs  : replicate(0),
            isSop      : 0
        };
        let isEop = PcieTlpCtlIsEopCommon {
            isEopPtrs  : replicate(0),
            isEop      : 0
        };
    // This cycle isInStreamA, only transfer StreamA or StreamA + StreamB
        if (isInStreamAReg) begin
        // First: get the whole streamA data to transfer to the PCIe bus in this cycle
            if (hasStreamARemainReg && hasLastStreamARemainReg) begin
                straddleWpA = remainStreamAWpReg;
                isInStreamAReg <= False;
                hasStreamARemainReg <= False;
            end
            else if (hasStreamARemainReg) begin
                let {concatStreamWpA, remainStreamWpA} = getConcatStream(remainStreamAWpReg, dataPrepareAFifo.first);
                dataPrepareAFifo.deq;
                if (isByteEnZero(remainStreamWpA.stream.byteEn)) begin
                    isInStreamAReg <= False;
                    hasStreamARemainReg <= False;
                end 
                else begin
                    isInStreamAReg <= True;
                    hasStreamARemainReg <= True;
                end
                straddleWpA = concatStreamWpA;
                remainStreamAWpReg <= remainStreamWpA;
                hasLastStreamARemainReg <= dataPrepareAFifo.first.stream.isLast;
            end
            else begin
                straddleWpA = dataPrepareAFifo.first;
                dataPrepareAFifo.deq;
            end
            if (dataPrepareBFifo.notEmpty) begin
                straddleWpB = dataPrepareBFifo.first;
            end
        // Second: generate straddle data
            straddleData = straddleWpA.stream.data;
            if (straddleWpA.stream.isLast) begin
                isEop.isEop = fromInteger(valueOf(SINGLE_TLP_IN_THIS_BEAT));
                isEop.isEopPtrs[0] = convertByteEn2DwordPtr(straddleWpA.stream.byteEn);
            end
            // only can contains straddleA
            if (straddleWpA.bytePtr > fromInteger(valueOf(STRADDLE_THRESH_WIDTH))) begin
                
            end
            // transfer straddleA and straddleB at the same time
            else begin
                if (straddleWpB.bytePtr > 0) begin

                end
                else begin

                end
            end
        end
        // This cycle isInStreamB, only transfer StreamB or StreamB + StreamA
        else if (isInStreamBReg) begin
            // get the whole streamB data to transfer to the PCIe bus in this cycle
            if (hasStreamBRemainReg && hasLastStreamBRemainReg) begin
                straddleWpB = remainStreamBWpReg;
                isInStreamBReg <= False;
                hasStreamBRemainReg <= False;
            end
            else if (hasStreamBRemainReg) begin
                dataPrepareBFifo.deq;
                let {concatStreamWpB, remainStreamWpB} = getConcatStream(remainStreamBWpReg, dataPrepareBFifo.first);
                if (isByteEnZero(remainStreamWpB.stream.byteEn)) begin
                    isInStreamBReg <= False;
                    hasStreamBRemainReg <= False;
                end 
                else begin
                    isInStreamBReg <= True;
                    hasStreamBRemainReg <= True;
                end
                straddleWpB = concatStreamWpB;
                remainStreamBWpReg <= remainStreamWpB;
                hasLastStreamBRemainReg <= dataPrepareBFifo.first.stream.isLast;
            end
            else begin
                straddleWpB = dataPrepareBFifo.first;
                dataPrepareBFifo.deq;
            end
            if (dataPrepareAFifo.notEmpty) begin
                straddleWpA = dataPrepareAFifo.first;
            end
        end
        // This cycle is idle
        else begin
            if (dataPrepareAFifo.notEmpty) begin
                straddleWpA = dataPrepareAFifo.first;
                dataPrepareAFifo.deq;
            end
            if (dataPrepareBFifo.notEmpty) begin
                straddleWpB = dataPrepareBFifo.first;
                dataPrepareBFifo.deq;
            end
        end

    endrule



    interface dataAFifoIn = convertFifoToFifoIn(dataInAFifo);
    interface reqAFifoIn  = convertFifoToFifoIn(reqInAFifo);
    interface dataBFifoIn = convertFifoToFifoIn(dataInBFifo);
    interface reqBFifoIn  = convertFifoToFifoIn(reqInBFifo);

endmodule

interface AlignedDescGen;
    interface FifoIn#(DmaRequest)  reqFifoIn;
    interface FifoOut#(DataStream) dataFifoOut;
    interface FifoOut#(SideBandByteEn) byteEnFifoOut;
endinterface

typedef Tuple5#(
    DmaRequest  ,
    ByteModDWord,
    ByteModDWord,
    DataBytePtr     ,
    DmaMemAddr  
 ) AlignedDescGenPipeTuple;

// Descriptor is 4DW aligned while the input datastream may be not
// This module will add 0~3 Bytes Dummy Data in the end of DescStream to make sure concat(desc, data) is aligned
module mkAlignedRqDescGen(Bool isWrite, AlignedDescGen ifc);
    FIFOF#(DmaRequest)      reqInFifo     <- mkFIFOF;
    FIFOF#(DataStream)      dataOutFifo   <- mkFIFOF;
    FIFOF#(SideBandByteEn)  byteEnOutFifo <- mkFIFOF;

    FIFOF#(AlignedDescGenPipeTuple) pipelineFifo <- mkFIFOF;

    function DwordCount getDWordCount(DmaMemAddr startAddr, DmaMemAddr endAddr);
        let endOffset = byteModDWord(endAddr); 
        DwordCount dwCnt = (endAddr >> valueOf(BYTE_DWORD_SHIFT_WIDTH)) - (startAddr >> valueOf(BYTE_DWORD_SHIFT_WIDTH));
        return (endOffset == 0) ? dwCnt : dwCnt + 1;
    endfunction

    // Pipeline Stage 1: calculate endAddress, first/lastBytePtr and aligned BytePtr
    rule getAlignedPtr;
        let request = reqInFifo.first;
        reqInFifo.deq;
        immAssert(
            (request.length <= fromInteger(valueOf(BUS_BOUNDARY))),
            "Request Check @ mkAlignedRqDescGen",
            fshow(request)
        );
        DmaMemAddr   endAddress   = request.startAddr + length - 1;
        // firstOffset values from {0, 1, 2, 3}
        ByteModDWord firstOffset  = byteModDWord(request.startAddr);
        ByteModDWord lastOffset   = byteModDWord(endAddress);
        ByteModDWord alignOffset  = ~firstOffset + 1;
        DataBytePtr  bytePtr      = fromInteger(valueOf(TDiv#(DES_RQ_DESCRIPTOR_WIDTH, BYTE_WIDTH))) + zeroExtend(alignOffset);
        pipelineFifo.enq(tuple5(
            request,
            firstOffset,
            lastOffset,
            bytePtr,
            endAddress)
        );
    endrule

    // Pipeline Stage 2: generate Descriptor and the dataStream
    rule genDescriptor;
        let {request, firstBytePtr, lastBytePtr, bytePtr, endAddress} = pipelineFifo.first;
        pipelineFifo.deq;
        let firstByteEn = convertDWordOffset2FirstByteEn(firstOffset);
        let lastByteEn  = convertDWordOffset2LastByteEn(lastOffset);
        let dwordCnt    = getDWordCount(request.startAddr, endAddress);
        lastByteEn = (request.startAddr == endAddress) ? 0 : lastByteEn;
        let byteEn      = convertBytePtr2ByteEn(bytePtr);
        let descriptor  = PcieRequesterRequestDescriptor {
            forceECRC       : False,
            attributes      : 0,
            trafficClass    : 0,
            requesterIdEn   : False,
            completerId     : 0,
            tag             : 0,
            requesterId     : 0,
            isPoisoned      : False,
            reqType         : isWrite ? fromInteger(valueOf(MEM_WRITE_REQ)) : fromInteger(valueOf(MEM_READ_REQ)),
            dwordCnt        : dwordCnt,
            address         : truncate(request.startAddr >> valueOf(BYTE_DWORD_SHIFT_WIDTH)),
            addrType        : fromInteger(valueOf(TRANSLATED_ADDR))
        };
        let stream = DataStream {
            data    : zeroExtend(pack(descriptor)),
            byteEn  : byteEn,
            isFirst : True,
            isLast  : True
        };
        dataOutFifo.enq(stream);
        byteEnOutFifo.enq(tuple2(firstByteEn, lastByteEn));
    endrule

    interface  reqFifoIn     =  convertFifoToFifoIn(reqInFifo);
    interface  dataFifoOut   =  convertFifoToFifoOut(dataOutFifo);
    interface  byteEnFifoOut =  convertFifoToFifoOut(byteEnOutFifo);
endmodule
