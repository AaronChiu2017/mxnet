#!/usr/bin/env python

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# pylint: disable=too-many-lines, unused-argument
"""ragged ndarray and util functions."""

from .ndarray import NDArray, _DTYPE_NP_TO_MX, _GRAD_REQ_MAP
from ..context import current_context
from ..numpy import ndarray
import numpy as _np



def ragged_array(object, dtype=None, ctx=None):
    """

    Parameters
    ----------
    object : array_like or `numpy.ndarray` or `mxnet.numpy.ndarray` or
     `mxnet.ragged.RaggedNDArray`. An array, any object exposing the array interface,
      an object whose __array__ method returns an array, or any (nested) sequence.
    dtype : data-type, optional
        The desired data-type for the array. Default is `float32`.
    ctx : device context, optional
        Device context on which the memory is allocated. Default is
        `mxnet.context.current_context()`.

    Returns
    -------
    out : RaggedNDArray
        An array object satisfying the specified requirements.

    """
    if isinstance(object, (ndarray, _np.ndarray)):

    elif isinstance(object, ())




class RaggedNDArray(NDArray):
    """The base class of a RaggedNDArray
    """
    def __repr__(self):
        """Returns a string representation of the array."""
        shape_info = 'x'.join(['%d' % x for x in self.shape])
        return '\n%s\n<%s %s @%s>' % (str(self.asnumpy()),
                                      self.__class__.__name__,
                                      shape_info, self.ctx)

    def __getitem__(self, key):
        """Return self[key].

        Returns a sliced view of this array if the elements fetched are contiguous in memory;
        otherwise, returns a newly created NDArray.
        This functions supports advanced indexing defined in the following reference with
        some restrictions. Boolean indexing is supported only for a single boolean ndarray
        as a key. Mixing boolean ndarray with other index types is not supported in ``advanced``
        indexing.

        For basic indexing, i.e., if ``key`` consists only of integers,
        ``slice``, ``Ellipsis`` (``...``) and ``None``, a mutable view is
        returned that shares memory with this array if the accessed portion is
        contiguous in memory.
        Otherwise, a newly created ``ndarray`` is returned.

        This functions supports advanced indexing as defined in `the NumPy
        advanced indexing documentation
        <https://docs.scipy.org/doc/numpy/reference/arrays.indexing.html#advanced-indexing>`_.

        Parameters
        ----------
        key : int, slice, list, np.ndarray, mx.np.ndarray, or tuple of all previous types
            Indexing key.
        """
        raise NotImplementedError
