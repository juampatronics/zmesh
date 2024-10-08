# cython:language_level = 3
# distutils: language = c++
import cython

from libc.stdint cimport uint64_t, uint32_t, uint16_t, uint8_t
from libcpp.vector cimport vector
from libcpp cimport bool

import operator
from functools import reduce
import sys

cimport numpy as cnp
import numpy as np
from zmesh.mesh import Mesh

cdef extern from "cMesher.hpp":
  cdef struct MeshObject:
    vector[float] points
    vector[float] normals
    vector[unsigned int] faces

  cdef cppclass CMesher[P,L,S]:
    CMesher(vector[float] voxel_res) except +
    void mesh(
      L* data, 
      unsigned int sx, 
      unsigned int sy, 
      unsigned int sz, 
      bool c_order
    )
    vector[L] ids()
    MeshObject get_mesh(
      L segid, 
      bool normals,
      int simplification_factor, 
      float max_simplification_error, 
      float min_simplification_error,
      bool transpose
    )
    # NOTE: need to define triangle_t
    MeshObject simplify_points(
      uint64_t* points, 
      size_t Nv, 
      bool normals, 
      int simplification_factor, 
      float max_simplification_error,
      float min_simplification_error,
    )
    bool erase(L segid)
    void clear()
    P pack_coords(P x, P y, P z)

class Mesher:
  """
  Represents a meshed volume. 

  Call mesher.mesh(labels) then you can 
  extract meshes from it using mesher.get(label).
  """
  def __init__(self, voxel_res):
    self.voxel_res = voxel_res
    self._mesher = Mesher6464(self.voxel_res)

  @property
  def voxel_res(self):
    return self._voxel_res

  @voxel_res.setter
  def voxel_res(self, res):
    self._voxel_res = np.array(res, dtype=np.float32)

  @cython.binding(True)
  def mesh(self, data, close=False):
    """
    Triggers the multi-label meshing process.
    After the mesher has run, you can call mesher.get.

    data: 3d numpy array
    close: By default, meshes flush against the edge of
      the image will be left open on the sides that touch
      the boundary. If True, this ensures that all meshes
      produced will be closed.
    """
    del self._mesher

    if not data.flags.c_contiguous and not data.flags.f_contiguous:
      data = np.ascontiguousarray(data)

    if close:
      tmp = np.zeros(np.array(data.shape) + 2, dtype=data.dtype, order="C")
      tmp[1:-1,1:-1,1:-1] = data
      data = tmp
      del tmp

    shape = np.array(data.shape)
    nbytes = np.dtype(data.dtype).itemsize

    # z is allocated 10 position bits, y 11, and x 11 bits.
    # The last bit is 2^-1 (fixed point) so divide by two to
    # get the maximum supported shape. 
    if shape[0] > 1023 or shape[1] > 1023 or shape[2] > 511:
      MesherClass = Mesher6464
      if nbytes == 4:
        MesherClass = Mesher6432
      elif nbytes == 2:
        MesherClass = Mesher6416
      elif nbytes == 1:
        MesherClass = Mesher6408
    else:
      MesherClass = Mesher3264
      if nbytes == 4:
        MesherClass = Mesher3232
      elif nbytes == 2:
        MesherClass = Mesher3216
      elif nbytes == 1:
        MesherClass = Mesher3208

    self._mesher = MesherClass(self.voxel_res)

    return self._mesher.mesh(data)

  @cython.binding(True)
  def ids(self):
    return self._mesher.ids()

  @cython.binding(True)
  def get_mesh(
    self, mesh_id, normals=False, 
    simplification_factor=0, max_simplification_error=40,
    voxel_centered=False
  ):
    """
    NOTE: This function is deprecated. Please use "get" as 
    this function transposes the mesh.

    mesh_id: the integer id of the mesh
    normals: whether to calculate vertex normals for the mesh
    simplification_factor: Try to reduce the number of triangles by this factor.
    max_simplification_error: maximum distance vertices are allowed to deviate from
      their original position. Units are physical, not voxels.
    voxel_centered: By default, the meshes produced will be centered at 0,0,0.
      If enabled, the meshes will be centered in the voxel at 0.5,0.5,0.5.

    Returns: Mesh
    """
    mesh = self._mesher.get_mesh(
      mesh_id, normals, 
      simplification_factor, max_simplification_error, 
      transpose=True
    )

    return self._normalize_simplified_mesh(mesh, voxel_centered, physical=True)

  @cython.binding(True)
  def get(
    self, label, 
    normals = False, 
    reduction_factor = 0, 
    max_error = None,
    voxel_centered = False
  ):
    """
    label: the integer id of the mesh
    normals: whether to calculate vertex normals for the mesh
    reduction_factor: Try to reduce the number of triangles by this integer factor. 
      0 disables simplification.
    max_error: maximum distance vertices are allowed to deviate from
      their original position. Units are physical, not voxels. If None, automatically
      is set to at most one voxel distortion based on the provided resolution.
    voxel_centered: By default, the meshes produced will be centered at 0,0,0.
      If enabled, the meshes will be centered in the voxel at 0.5,0.5,0.5.

    Returns: Mesh
    """
    # automatically select one voxel max distortion
    if max_error is None:
      max_error = self.voxel_res.max()

    mesh = self._mesher.get_mesh(
      label, normals, 
      reduction_factor, max_error,
      transpose=False
    )

    mesh = self._normalize_simplified_mesh(mesh, voxel_centered, physical=True)
    mesh.id = int(label)
    return mesh

  def _normalize_simplified_mesh(self, mesh, voxel_centered, physical):
    points = np.array(mesh['points'], dtype=np.float32)
    Nv = points.size // 3
    Nf = len(mesh['faces']) // 3

    points = points.reshape(Nv, 3)
    if not physical:
      points *= self.voxel_res

    if voxel_centered:
      points += self.voxel_res
    points /= 2.0
    faces = np.array(mesh['faces'], dtype=np.uint32).reshape(Nf, 3)
    
    normals = None
    if mesh['normals']:
      normals = np.array(mesh['normals'], dtype=np.float32).reshape(Nv, 3)

    return Mesh(points, faces, normals)

  @cython.binding(True)
  def compute_normals(self, mesh):
    """
    Returns: Mesh with normals computed
    """
    return self.simplify(mesh, reduction_factor=0, max_error=0, compute_normals=True)

  # adding this causes a cython compilation error as of 3.0.10
  # @cython.binding(True)
  def simplify(
    self, mesh, 
    int reduction_factor = 0, 
    float max_error = 40, 
    compute_normals = False,
    voxel_centered = False, 
    float min_error = -1,
  ):
    """
    Mesh simplify(
      mesh, reduction_factor=0, 
      max_error=40, compute_normals=False, 
      voxel_centered=False, min_error = -1
    )

    Given a mesh object (either zmesh.Mesh or another object that has
    mesh.vertices and mesh.faces implemented as numpy arrays), apply
    the quadratic edge collapse algorithm. 

    Note: the maximum range spread between vertex values (in x, y, or z)
    is 2^20. The simplifier cannot represent values outside that range.

    Optional:
      reduction_factor: Triangle reduction factor target. If all vertices
        are maxxed out in terms of their error tolerance the algorithm will
        stop short of this target.
      max_error: The maximum allowed displacement of a vertex in physical
        distance.
      min_error: Continue simplifying until this error target is met OR secondarily 
        the target number of triangles is met. Set this to 0 to force the 
        reduction_factor to take precedence. -1 indicates that the c++ default
        value should be used.

        The c++ default value is std::numeric_limits<Float>::epsilon() * 25

      compute_normals: whether or not to also compute the vertex normals
      voxel_centered: By default, the meshes produced will be centered at 
        0,0,0. If enabled, the meshes will be centered in the voxel at 
        0.5,0.5,0.5.

    Returns: Mesh
    """
    mesher = new CMesher[uint64_t, uint64_t, float]((1,1,1))

    cdef size_t ti = 0
    cdef size_t vi = 0
    cdef uint64_t vert = 0

    cdef cnp.ndarray[float, ndim=3] triangles = mesh.vertices[mesh.faces]
    cdef cnp.ndarray[uint64_t, ndim=2] packed_triangles = np.zeros( 
      (triangles.shape[0], 3), dtype=np.uint64, order='C'
    ) 

    max_error //= np.sqrt(np.sum(self.voxel_res ** 2))

    triangles /= self.voxel_res
    triangles *= 2.0
    cdef float min_vertex = np.min(triangles)
    if min_vertex != 0:
      triangles -= min_vertex

    # uint64 // 3 = 21 bits - 1 bit for representing half voxels
    if np.max(triangles) > 2**20:
      raise ValueError(
        "Vertex positions larger than simplifier representation limit (2^20). "
        f"Did you set the resolution correctly? voxel res: {self.voxel_res}"
      )

    cdef size_t Nv = triangles.shape[0]

    for ti in range(Nv):
      for vi in range(3):
        packed_triangles[ti, vi] = mesher.pack_coords(
          <uint64_t>triangles[ti, vi, 0], <uint64_t>triangles[ti, vi, 1], <uint64_t>triangles[ti, vi, 2]
        )
    del triangles

    cdef MeshObject result = mesher.simplify_points(
      <uint64_t*>&packed_triangles[0,0], Nv, 
      <bool>compute_normals, reduction_factor, 
      max_error, min_error
    )
    del mesher

    cdef int i = 0
    if min_vertex != 0:
      for i in range(len(result.points)):
        result.points[i] += min_vertex

    return self._normalize_simplified_mesh(result, voxel_centered, physical=False)
  
  def clear(self):
    self._mesher.clear()
  
  @cython.binding(True) 
  def erase(self, segid):
    return self._mesher.erase(segid)

def reshape(arr, shape, order=None):
  """
  If the array is contiguous, attempt an in place reshape
  rather than potentially making a copy.

  Required:
    arr: The input numpy array.
    shape: The desired shape (must be the same size as arr)

  Optional: 
    order: 'C', 'F', or None (determine automatically)

  Returns: reshaped array
  """
  if order is None:
    if arr.flags['F_CONTIGUOUS']:
      order = 'F'
    elif arr.flags['C_CONTIGUOUS']:
      order = 'C'
    else:
      return arr.reshape(shape)

  cdef int nbytes = np.dtype(arr.dtype).itemsize

  if order == 'C':
    strides = [ reduce(operator.mul, shape[i:]) * nbytes for i in range(1, len(shape)) ]
    strides += [ nbytes ]
    return np.lib.stride_tricks.as_strided(arr, shape=shape, strides=strides)
  else:
    strides = [ reduce(operator.mul, shape[:i]) * nbytes for i in range(1, len(shape)) ]
    strides = [ nbytes ] + strides
    return np.lib.stride_tricks.as_strided(arr, shape=shape, strides=strides)


# NOTE: THE USER INTERFACE CLASS IS "Mesher" ABOVE

# The following wrapper classes are generated from a template!!

# The pattern is: Mesher[PositionType bits][LabelType bits]
# 64 bit position type can represent very large arrays
# 32 bit can represent 1023 x 1023 x 511 arrays
cdef class Mesher3208:
  cdef CMesher[uint32_t, uint8_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint32_t, uint8_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint8_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint8)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

cdef class Mesher3216:
  cdef CMesher[uint32_t, uint16_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint32_t, uint16_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint16_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint16)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

cdef class Mesher3232:
  cdef CMesher[uint32_t, uint32_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint32_t, uint32_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint32_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint32)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

cdef class Mesher3264:
  cdef CMesher[uint32_t, uint64_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint32_t, uint64_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint64_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint64)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

cdef class Mesher6408:
  cdef CMesher[uint64_t, uint8_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint64_t, uint8_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint8_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint8)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

cdef class Mesher6416:
  cdef CMesher[uint64_t, uint16_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint64_t, uint16_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint16_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint16)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

cdef class Mesher6432:
  cdef CMesher[uint64_t, uint32_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint64_t, uint32_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint32_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint32)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

cdef class Mesher6464:
  cdef CMesher[uint64_t, uint64_t, float] *ptr      # hold a C++ instance which we're wrapping

  def __cinit__(self, voxel_res):
    self.ptr = new CMesher[uint64_t, uint64_t, float](voxel_res)

  def __dealloc__(self):
    del self.ptr

  def mesh(self, data):
    cdef cnp.ndarray[uint64_t, ndim=1] flat_data = reshape(data, (data.size,)).view(np.uint64)
    self.ptr.mesh(
      &flat_data[0],
      data.shape[0], data.shape[1], data.shape[2],
      data.flags.c_contiguous
    )

  def ids(self):
    return self.ptr.ids()
  
  def get_mesh(self, mesh_id, normals=False, simplification_factor=0, max_simplification_error=40, min_simplification_error=(25 * sys.float_info.epsilon), transpose=True):
    return self.ptr.get_mesh(mesh_id, normals, simplification_factor, max_simplification_error, min_simplification_error, transpose)
  
  def clear(self):
    self.ptr.clear()

  def erase(self, mesh_id):
    return self.ptr.erase(mesh_id)

