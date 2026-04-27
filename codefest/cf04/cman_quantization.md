# Codefest 4 CMAN
# S = max(|W|)/127 = 0.018188976377952755

## Quantized W_q:
 [  47.  -66.   19.  115.]
 [  -4.   50. -103.    7.]
 [  85.    2.  -24. -127.]
 [ -10.   57.   42.   30.]

## W_deq dequantized:
 [ 0.85488189 -1.20047244  0.34559055  2.09173228]
 [-0.07275591  0.90944882 -1.87346457  0.12732283]
 [ 1.54606299  0.03637795 -0.43653543 -2.31      ]
 [-0.18188976  1.03677165  0.76393701  0.54566929]
## Max absolute error:  0.008267716535433234
## Mean absolute error:  0.004325787401574841
# S_bad = 0.01


## Quantized W bad:
 [  85. -120.   34.  127.]
 [  -7.   91. -128.   12.]
 [ 127.    3.  -44. -128.]
 [ -18.  103.   77.   55.]

## W_deq_bad: 
 [ 0.85 -1.2   0.34  1.27]
 [-0.07  0.91 -1.28  0.12]
 [ 1.27  0.03 -0.44 -1.28]
 [-0.18  1.03  0.77  0.55]

## Max absolute error with S = 0.01: 1.03

### Element with max absolute error:  -1.28 Original value:  -2.31

## Mean absolute error with S = 0.01:  0.17125
## Explanation for bad mean absolute error with S = 0.01:
 A scaling factor of 0.01 causes some values to exceed -128 when quantized (for example -231), which results in a loss of accuracy since these values are clamped to -128.
