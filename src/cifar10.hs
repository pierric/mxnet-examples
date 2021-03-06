module Main where

import           Control.Lens                (ix, use, (^?!))
import           Formatting                  (float, int, sformat, stext, (%))
import           Options.Applicative
import           RIO
import qualified RIO.HashMap                 as M
import qualified RIO.HashSet                 as S
import           RIO.List.Partial            (last)
import qualified RIO.Text                    as T

import           MXNet.Base                  (ArgOf (..), HMap (..), contextCPU,
                                              contextGPU0, listArguments,
                                              ndshape, (.&))
import           MXNet.Base.Tensor
import           MXNet.NN
import           MXNet.NN.DataIter.Streaming
import qualified MXNet.NN.Initializer        as I
import qualified MXNet.NN.ModelZoo.Resnet    as Resnet
import qualified MXNet.NN.ModelZoo.Resnext   as Resnext

batch_size = 128

data Model = Resnet
    | Resnext
    deriving (Show, Read)
data ProgArg = ProgArg Model (Maybe String)
cmdArgParser :: Parser ProgArg
cmdArgParser = ProgArg
                <$> (option auto  $ short 'm' <> metavar "MODEL" <> showDefault <> value Resnet)
                <*> (option maybe $ short 'p' <> metavar "PRETRAINED" <> showDefault <> value Nothing)
  where
    maybe = maybeReader (Just . Just)

default_initializer :: Initializer Float
default_initializer name arr
    | T.isSuffixOf ".bias"  name = I.zeros name arr
    | T.isSuffixOf ".beta"  name = I.zeros name arr
    | T.isSuffixOf ".gamma" name = I.ones  name arr
    | T.isSuffixOf ".running_mean" name = I.zeros name arr
    | T.isSuffixOf ".running_var"  name = I.ones  name arr
    | otherwise = do
        shp <- ndshape arr
        case shp of
          [_,_] -> I.xavier 2.0 I.XavierGaussian I.XavierIn name arr
          _     -> I.normal 0.1 name arr

main :: IO ()
main = runFeiM . Simple $ do
    ProgArg model pretrained <- liftIO $ execParser $ info
        (cmdArgParser <**> helper) (fullDesc <> header "CIFAR-10 solver")

    net  <- runLayerBuilder $ do
                dat <- variable "x"
                lbl <- variable "y"
                logits <- case model of
                    Resnet  -> Resnet.resnet50 10 dat
                    Resnext -> Resnext.symbol dat
                named "softmax" $ softmaxoutput  (#data := logits .& #label := lbl .& Nil)

    fixed <- case pretrained of
        Nothing -> return S.empty
        Just _  -> fixedParams net model

    initSession @"cifar10" net (Config {
        _cfg_data = M.singleton "x" [batch_size, 3,32,32],
        _cfg_label = ["y"],
        _cfg_initializers = M.empty,
        _cfg_default_initializer = default_initializer,
        _cfg_fixed_params = fixed,
        _cfg_context = contextGPU0 })

    let lr_scheduler = lrOfMultifactor $ #steps := [100, 200, 300]
                                      .& #base := 0.0001
                                      .& #factor:= 0.75 .& Nil
        ce  = CrossEntropy Nothing True
                  (\_ p -> p ^?! ix 0)
                  (\b _ -> b ^?! ix "y")
        acc = Accuracy Nothing PredByArgmax 0
                  (\_ p -> p ^?! ix 0)
                  (\b _ -> b ^?! ix "y")

    optimizer <- makeOptimizer SGD'Mom lr_scheduler Nil

    let trainingData = imageRecordIter (#path_imgrec := "data/cifar10_train.rec"
                                     .& #data_shape  := [3,32,32]
                                     .& #batch_size  := batch_size .& Nil)
        valData      = imageRecordIter (#path_imgrec := "data/cifar10_val.rec"
                                     .& #data_shape  := [3,32,32]
                                     .& #batch_size  := 16 .& Nil)
    askSession $ case pretrained of
        Just path -> loadState path ["output.weight", "output.bias"]
        Nothing   -> return ()

    forM_ ([1..20] :: [Int]) $ \ ei -> do
        logInfo . display $ sformat ("Epoch " % int) ei
        metric <- newMetric "train" (ce :* acc :* MNil)
        void $ forEachD_i trainingData $ \(i, (x, y)) -> askSession $ do
            let binding = M.fromList [("x", x), ("y", y)]
            fitAndEval optimizer binding metric
            eval <- metricFormat metric
            lr <- use (untag . mod_statistics . stat_last_lr)
            when (i `mod` 20 == 0) $ do
                logInfo . display $ sformat (int % " " % stext % " LR: " % float) i eval lr

        metric <- newMetric "val" (acc :* MNil)
        void $ forEachD_i valData $ \(_, (x, y)) -> askSession $ do
            pred <- forwardOnly (M.singleton "x" x)
            void $ metricUpdate metric (M.singleton "y" y) pred
        eval <- metricFormat metric
        logInfo . display $ sformat ("Validation: " % stext) eval

fixedParams symbol _ = do
    argnames <- listArguments symbol
    return $ S.fromList [n | n <- argnames
                        -- fix conv_0, stage_1_*, *_gamma, *_beta
                        , layer n `elemL` ["1", "5"] || name n `elemL` ["gamma", "beta"]]

  where
    layer param = case T.split (=='.') param of
                    "features":n:_ -> n
                    _              -> "<na>"
    name param = last $ T.split (=='.') param
    elemL :: Eq a => a -> [a] -> Bool
    elemL = elem
