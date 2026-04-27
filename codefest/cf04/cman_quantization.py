import numpy as np

W = np.array([[0.85,-1.2,0.34,2.1],[-0.07, 0.91, -1.88, 0.12],[1.55,0.03,-0.44,-2.31],[-0.18,1.03,0.77,0.55]])


S = np.max(np.abs(W)) / 127.0
print('# Codefest 4 CMAN')
print('## S = max(|W|)/127:')
print(S)
W_q = np.round(W / S)

print("\n## Quantized W_q:")
print(W_q)

W_deq = W_q * S

print('\n## W_deq dequantized:')
print(W_deq)

W_abs_err = np.abs(W - W_deq)

err_max = np.max(W_abs_err)

print("## Max absolute error: ", err_max)
mean_err = np.mean(W_abs_err)
print("## Mean absolute error: ", mean_err)

S_bad = 0.01
print("## S_bad = 0.01")
W_q_bad = np.round(W / S_bad)
W_q_bad = np.clip(W_q_bad, -128,127)
print('\n\n## Quantized W bad:')
print(W_q_bad)
W_deq_bad = W_q_bad * S_bad
print('\n## W_deq_bad: ')
print(W_deq_bad)

W_abs_err_bad = np.abs(W - W_deq_bad)
err_bad_max = np.max(W_abs_err_bad)
row, col = np.unravel_index(np.argmax(W_abs_err_bad), W_abs_err_bad.shape)
mean_err_bad = np.mean(W_abs_err_bad)
print("\n## Max absolute error with S = 0.01:", err_bad_max)
print("\n### Element with max absolute error: ", W_deq_bad[row][col], "Original value: ", W[row][col])
print("\n## Mean absolute error with S = 0.01: ", mean_err_bad)
print("## Explanation for bad mean absolute error with S = 0.01:\n A scaling factor of 0.01 causes some values to exceed -128 when quantized (for example -231), which results in a loss of accuracy since these values are clamped to -128.")
