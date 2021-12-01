func @matmul(%a: tensor<${M}x${K}xf32>, %b: tensor<${K}x${N}xf32>, %c: tensor<${M}x${N}xf32>)
  -> tensor<${M}x${N}xf32>
{
  %f0 = arith.constant 0.0 : f32
  %f1 = linalg.fill(%f0, %c) : f32, tensor<${M}x${N}xf32> -> tensor<${M}x${N}xf32>
  %d = linalg.matmul ins(%a, %b : tensor<${M}x${K}xf32>, tensor<${K}x${N}xf32>)
    outs(%f1: tensor<${M}x${N}xf32>) -> tensor<${M}x${N}xf32>
  return %d: tensor<${M}x${N}xf32>
}