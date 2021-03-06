/*!
*  Copyright (c) 2017 by Contributors
* \file nn_addition_op.cc
* \brief CPU Implementation of nn additional operations
*/
// this will be invoked by gcc and compile CPU version
#include "./nn_addition_op-inl.h"
#include "./elemwise_unary_op.h"
#include "./elemwise_binary_op.h"

namespace mxnet {
namespace op {
DMLC_REGISTER_PARAMETER(LocalCorrelationParam);
DMLC_REGISTER_PARAMETER(LocalSparseFilterParam);
DMLC_REGISTER_PARAMETER(BinaryStochasticNeuronParam);
DMLC_REGISTER_PARAMETER(ArgSortLastParam);

NNVM_REGISTER_OP(LocalCorrelation)
.MXNET_DESCRIBE("Calculate the inner product between the vector lhs_{:, i, j} and rhs_{:, N(i), N(j)}."
                " lhs will be of shape (B, C, H_1, W_1), rhs will be of shape (B, C, H_2, W_2)."
                " The output will have shape (B, H_1, W_1, ksize_y, ksize_x).")
.set_num_inputs(2)
.set_num_outputs(1)
.set_attr_parser(ParamParser<LocalCorrelationParam>)
.set_attr<nnvm::FInferShape>("FInferShape", LocalCorrelationShape)
.set_attr<nnvm::FInferType>("FInferType", ElemwiseType<2, 1>)
.set_attr<FCompute>("FCompute<cpu>", LocalCorrelationForward_<cpu>)
.set_attr<FResourceRequest>("FResourceRequest",
  [](const NodeAttrs& attrs) {
    return std::vector<ResourceRequest>{ResourceRequest::kTempSpace};
  })
.set_attr<nnvm::FListInputNames>("FListInputNames",
  [](const NodeAttrs& attrs) {
    return std::vector<std::string>{"lhs", "rhs"};
  })
.set_attr<nnvm::FGradient>("FGradient", ElemwiseGradUseIn{"_backward_LocalCorrelation"})
.add_argument("lhs", "NDArray", "lhs data, the query input data that we want to find the correlation weights")
.add_argument("rhs", "NDArray", "rhs data, the search data that we will try to attend the lhs on.");

NNVM_REGISTER_OP(_backward_LocalCorrelation)
.set_num_inputs(3)
.set_num_outputs(2)
.set_attr_parser(ParamParser<LocalCorrelationParam>)
.set_attr<FResourceRequest>("FResourceRequest",
  [](const NodeAttrs& attrs) {
    return std::vector<ResourceRequest>{ResourceRequest::kTempSpace};
  })
.set_attr<nnvm::TIsBackward>("TIsBackward", true)
.set_attr<FCompute>("FCompute<cpu>", LocalCorrelationBackward_<cpu>);

NNVM_REGISTER_OP(LocalSparseFilter)
.MXNET_DESCRIBE("The sparse local filter layer:"
                " data will be of shape (B, inC, H, W), indices will be of shape (B, H, W, L, K),"
                " values will be of shape (B, H, W, L, K)."
                " weight will be of shape (L, outC, inC), bias will be of shape (outC,)."
                " The output will have shape (B, outC, H, W).")
.set_num_inputs(5)
.set_num_outputs(1)
.set_attr_parser(ParamParser<LocalSparseFilterParam>)
.set_attr<nnvm::FInferShape>("FInferShape", LocalSparseFilterShape)
.set_attr<nnvm::FInferType>("FInferType", ElemwiseType<5, 1>)
.set_attr<FCompute>("FCompute<cpu>", LocalSparseFilterForward_<cpu>)
.set_attr<FResourceRequest>("FResourceRequest",
  [](const NodeAttrs& attrs) {
    return std::vector<ResourceRequest>{ResourceRequest::kTempSpace};
  })
.set_attr<nnvm::FListInputNames>("FListInputNames",
  [](const NodeAttrs& attrs) {
    return std::vector<std::string>{"data", "weight", "bias", "values", "indices"};
  })
.set_attr<nnvm::FGradient>("FGradient",
  [](const nnvm::NodePtr& n, const std::vector<nnvm::NodeEntry>& ograds) {
    auto ret = MakeNonlossGradNode("_backward_LocalSparseFilter", n, ograds,
                                   {n->inputs[0], n->inputs[1], n->inputs[3], n->inputs[4]}, n->attrs.dict);
    auto p = MakeNode("zeros_like", n->attrs.name + "_index_backward",
                      {n->inputs[4]}, nullptr, &n);
    ret.emplace_back(nnvm::NodeEntry{p, 0, 0});
    return ret;
  })
.add_argument("data", "NDArray-or-Symbol", "The data input, shape (B, inC, H, W)")
.add_argument("weight", "NDArray-or-Symbol", "The weight, shape (outC, inC, L)")
.add_argument("bias", "NDArray-or-Symbol", "The bias, shape (outC,)")
.add_argument("values", "NDArray-or-Symbol", "The value of the corresponding indices, shape (B, L, K, H, W)")
.add_argument("indices", "NDArray-or-Symbol", "The indices of the local connections, shape (B, L, K, H, W)");

NNVM_REGISTER_OP(_backward_LocalSparseFilter)
.set_num_inputs(5)
.set_num_outputs(4)
.set_attr_parser(ParamParser<LocalSparseFilterParam>)
.set_attr<FResourceRequest>("FResourceRequest",
  [](const NodeAttrs& attrs) {
    return std::vector<ResourceRequest>{ResourceRequest::kTempSpace};
  })
.set_attr<nnvm::TIsBackward>("TIsBackward", true)
.set_attr<FCompute>("FCompute<cpu>", LocalSparseFilterBackward_<cpu>);

// Binary Stochastic Neurons
NNVM_REGISTER_OP(BSN)
.MXNET_DESCRIBE("Binary Stochastic Neurons with the Straight-Through Estimator."
  " The input will be first mapped to [0, 1] using the sigmoid activation,"
  " which will be further converted to a hard {0, 1} by stochastic sample or"
  " deterministic rounding"
  " See \"[Arxiv2016]Hierarchical Multiscale Recurrent Neural Networks\""
  "for more detail")
  .set_num_inputs(1)
  .set_num_outputs(2)
  .set_attr_parser(ParamParser<BinaryStochasticNeuronParam>)
  .set_attr<nnvm::FInferShape>("FInferShape", ElemwiseShape<1, 2>)
  .set_attr<nnvm::FInferType>("FInferType", ElemwiseType<1, 2>)
  .set_attr<nnvm::FNumVisibleOutputs>("FNumVisibleOutputs", [](const NodeAttrs& attrs) {return 1;})
  .set_attr<nnvm::FInplaceOption>("FInplaceOption", [](const NodeAttrs& attrs) {
  return std::vector<std::pair<int, int> >{{0, 1}};
})
.set_attr<FCompute>("FCompute<cpu>", BinaryStochasticNeuronCompute<cpu>)
.set_attr<nnvm::FGradient>("FGradient", [](const nnvm::NodePtr& n,
  const std::vector<nnvm::NodeEntry>& ograds) {
  std::vector<nnvm::NodeEntry> heads(ograds.begin(), ograds.begin() + 1);
  heads.emplace_back(nnvm::NodeEntry{ n, 1, 0 });
  return MakeGradNode("_backward_BSN", n, heads, n->attrs.dict);
})
.set_attr<FResourceRequest>("FResourceRequest", [](const NodeAttrs& attrs) {
  std::vector<ResourceRequest> ret;
  ret.push_back(ResourceRequest::kRandom);
  return ret;
})
.add_argument("data", "NDArray-or-Symbol", "Source input")
.add_arguments(BinaryStochasticNeuronParam::__FIELDS__());

MXNET_OPERATOR_REGISTER_BINARY(_backward_BSN)
.set_attr<FCompute>("FCompute<cpu>", ElemwiseBinaryOp::Compute<cpu, unary_bwd<mshadow_op::sigmoid_grad>>);

NNVM_REGISTER_OP(argsort_last)
.describe(R"code(Returns the indices that would sort an input array along the last axis (equivalent to axis=-1).

Examples::

  x = [[ 0.3,  0.2,  0.4],
       [ 0.1,  0.3,  0.2]]

  // sort along axis -1
  argsort_last(x) = [[ 1.,  0.,  2.],
                [ 0.,  2.,  1.]]
)code" ADD_FILELINE)
.set_num_inputs(1)
.set_num_outputs(2)
.set_attr<nnvm::FNumVisibleOutputs>("FNumVisibleOutputs",
  [](const NodeAttrs& attrs) {
  return 1;
})
.set_attr_parser(ParamParser<ArgSortLastParam>)
.set_attr<nnvm::FInferShape>("FInferShape", ArgsortLastShape)
.set_attr<nnvm::FInferType>("FInferType",
  [](const nnvm::NodeAttrs& attrs,
    std::vector<int> *in_type,
    std::vector<int> *out_type) {
  out_type->clear();
  out_type->push_back((*in_type)[0]);
  out_type->push_back(mshadow::kInt32);
  return true;
})
.set_attr<FCompute>("FCompute<cpu>", ArgSortLast<cpu>)
.set_attr<nnvm::FGradient>("FGradient", MakeZeroGradNodes)
.set_attr<FResourceRequest>("FResourceRequest",
  [](const NodeAttrs& attrs) {
  return std::vector<ResourceRequest>{ResourceRequest::kTempSpace};
})
.add_argument("data", "NDArray-or-Symbol", "The input array")
.add_arguments(ArgSortLastParam::__FIELDS__());
}  // namespace op
}  // namespace mxnet
