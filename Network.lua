-- Handles the interaction of a fixed size deep neural network of 129 input spectrogram coeffecients and 28 output
-- for speech recognition.
require 'cunn'
require 'cudnn'
require 'CTCCriterion'
require 'optim'
require 'rnn'
require 'gnuplot'
require 'xlua'
local Network = {}

local logger = optim.Logger('train.log')
logger:setNames { 'loss' }
logger:style { '-' }

function Network:init(networkParams)
    self.loadModel = networkParams.loadModel or false -- If set to true we will load the model into Network.
    self.saveModel = networkParams.saveModel or false -- Set to true if you want to save the model after training.
    self.fileName = networkParams.fileName -- The file name to save/load the network from.
    self.model = nil
    if (Network.loadModel) then
        assert(networkParams.fileName, "Filename hasn't been given to load model.")
        Network:loadNetwork(networkParams.fileName)
    else
        Network:createSpeechNetwork()
    end
    assert((networkParams.saveModel or networkParams.loadModel) and networkParams.fileName, "To save/load you must specify the fileName you want to save to")
end

--Creates a new speech network loaded into Network.
function Network:createSpeechNetwork()
    torch.manualSeed(123)

    local cnn = nn.Sequential()

    cnn:add(cudnn.SpatialConvolution(1, 32, 41, 11, 2, 2))
    cnn:add(cudnn.SpatialBatchNormalization(32))
    cnn:add(cudnn.ReLU(true))
    cnn:add(nn.Dropout(0.4))
    cnn:add(cudnn.SpatialConvolution(32, 32, 21, 11, 2, 1))
    cnn:add(cudnn.SpatialBatchNormalization(32))
    cnn:add(cudnn.ReLU(true))
    cnn:add(nn.Dropout(0.4))
    cnn:add(cudnn.SpatialMaxPooling(2, 2, 2, 2))

    -- batchsize x featuremap x freq x time
    cnn:add(nn.SplitTable(1))
    -- features x freq x time
    cnn:add(nn.Sequencer(nn.View(1, 32 * 25, -1)))
    -- batch x features x time
    cnn:add(nn.JoinTable(1))
    -- batch x time x features
    cnn:add(nn.Transpose({ 2, 3 }))


    local model = nn.Sequential()
    model:add(cnn)
    model:add(nn.Transpose({ 1, 2 }))
    model:add(nn.SplitTable(1))
    model:add(nn.Sequencer(nn.Linear(32 * 25, 512)))
    model:add(nn.Sequencer(nn.BatchNormalization(512)))
    model:add(nn.Sequencer(nn.ReLU(true)))
    model:add(nn.Sequencer(nn.Dropout(0.5)))
    model:add(createBiDirectionalNetwork())
    model:add(nn.Sequencer(nn.BatchNormalization(200)))
    model:add(nn.Sequencer(nn.Linear(200, 28)))
    model:add(nn.Sequencer(nn.View(1, -1, 28)))
    model:add(nn.JoinTable(1))
    model:add(nn.Transpose({ 1, 2 }))
    model:cuda()
    Network.model = model
end

-- Creates the stack of bi-directional RNNs.
function createBiDirectionalNetwork()
    local biseqModel = nn.Sequential()
    biseqModel:add(nn.BiSequencer(nn.FastLSTM(512, 100)))
    biseqModel:add(nn.BiSequencer(nn.FastLSTM(200, 100)))
    biseqModel:add(nn.BiSequencer(nn.FastLSTM(200, 100)))
    biseqModel:add(nn.BiSequencer(nn.FastLSTM(200, 100)))
    biseqModel:add(nn.BiSequencer(nn.FastLSTM(200, 100)))
    return biseqModel;
end

-- Returns a prediction of the input net and input tensors.
function Network:predict(inputTensors)
    local prediction = Network.model:forward(inputTensors)
    return prediction
end

--Trains the network using SGD and the defined feval.
--Uses warp-ctc cost evaluation.
function Network:trainNetwork(dataset, epochs, sgd_params)
    local ctcCriterion = CTCCriterion()
    local x, gradParameters = Network.model:getParameters()

    -- GPU inputs (preallocate)
    local inputs = torch.CudaTensor()

    local function feval(x_new)
        local inputsCPU, targets = dataset:nextData()
        -- transfer over to GPU
        inputs:resize(inputsCPU:size()):copy(inputsCPU)
        gradParameters:zero()
        local predictions = Network.model:forward(inputs)
        local loss = ctcCriterion:forward(predictions, targets)
        Network.model:zeroGradParameters()
        local gradOutput = ctcCriterion:backward(predictions, targets)
        Network.model:backward(inputs, gradOutput)
        return loss, gradParameters
    end

    local currentLoss
    local startTime = os.time()
    local dataSetSize = dataset:size()
    for i = 1, epochs do
        local averageLoss = 0
        print(string.format("Training Epoch: %d", i))
        for j = 1, dataSetSize do
            collectgarbage()
            cutorch.synchronize()
            currentLoss = 0
            local _, fs = optim.sgd(feval, x, sgd_params)
            currentLoss = currentLoss + fs[1]
            xlua.progress(j, dataSetSize)
            averageLoss = averageLoss + currentLoss
        end
        averageLoss = averageLoss / dataSetSize -- Calculate the average loss at this epoch.
        logger:add { averageLoss } -- Add the average loss value to the logger.
        print(string.format("Training Epoch: %d Average Loss: %f", i, averageLoss))
    end
    local endTime = os.time()
    local secondsTaken = endTime - startTime
    print("Minutes taken to train: ", secondsTaken / 60)

    if (Network.saveModel) then
        print("Saving model")
        Network:saveNetwork(Network.fileName)
    end
end

function Network:createLossGraph()
    logger:plot()
end

function Network:saveNetwork(saveName)
    torch.save(saveName, Network.model)
end

--Loads the model into Network.
function Network:loadNetwork(saveName)
    local model = torch.load(saveName)
    Network.model = model
    model:evaluate()
end

return Network