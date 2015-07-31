# -- cython: profile=True

from libc.stdint cimport int64_t, int32_t

# from cassandra.marshal cimport (int8_pack, int8_unpack, int16_pack, int16_unpack,
#                                 uint16_pack, uint16_unpack, uint32_pack, uint32_unpack,
#                                 int32_pack, int32_unpack, int64_pack, int64_unpack, float_pack, float_unpack, double_pack, double_unpack)

# from cassandra.marshal import varint_pack, varint_unpack
# from cassandra import util
# from cassandra.cqltypes import EMPTY, LongType
from cassandra.protocol import ResultMessage, ProtocolHandler

# from cassandra.bytesio cimport BytesIOReader
from cassandra.parsing cimport ParseDesc, ColumnParser
from cassandra.datatypes import make_datatypes
from cassandra.objparser import ListParser


include "ioutils.pyx"


def make_recv_results_rows(ColumnParser colparser):
    def recv_results_rows(cls, f, protocol_version, user_type_map):
        """
        Parse protocol data given as a BytesIO f into a set of columns (e.g. list of tuples)
        This is used as the recv_results_rows method of (Fast)ResultMessage
        """
        paging_state, column_metadata = cls.recv_results_metadata(f, user_type_map)

        colnames = [c[2] for c in column_metadata]
        coltypes = [c[3] for c in column_metadata]

        desc = ParseDesc(colnames, coltypes, make_datatypes(coltypes), protocol_version)
        reader = BytesIOReader(f.read())
        parsed_rows = colparser.parse_rows(reader, desc)

        return (paging_state, (colnames, parsed_rows))

    return recv_results_rows


def make_protocol_handler(colparser=ListParser()):
    """
    Given a column parser to deserialize ResultMessages, return a suitable
    Cython-based protocol handler.

    There are three Cython-based protocol handlers (least to most performant):

        1. objparser.ListParser
            this parser decodes result messages into a list of tuples

        2. objparser.LazyParser
            this parser decodes result messages lazily by returning an iterator

        3. numpyparser.NumPyParser
            this parser decodes result messages into NumPy arrays

    The default is to use objparser.ListParser
    """
    # TODO: It may be cleaner to turn ProtocolHandler and ResultMessage into
    # TODO:     instances and use methods instead of class methods

    class FastResultMessage(ResultMessage):
        """
        Cython version of Result Message that has a faster implementation of
        recv_results_row.
        """
        # type_codes = ResultMessage.type_codes.copy()
        code_to_type = dict((v, k) for k, v in ResultMessage.type_codes.items())
        recv_results_rows = classmethod(make_recv_results_rows(colparser))

    class CythonProtocolHandler(ProtocolHandler):
        """
        Use FastResultMessage to decode query result message messages.
        """

        my_opcodes = ProtocolHandler.message_types_by_opcode.copy()
        my_opcodes[FastResultMessage.opcode] = FastResultMessage
        message_types_by_opcode = my_opcodes

    return CythonProtocolHandler


# cdef parse_rows2(BytesIOReader reader, list colnames, list coltypes, protocol_version):
#     cdef Py_ssize_t i, rowcount
#     cdef char *raw_val
#     cdef int[::1] colcodes
#
#     colcodes = np.array(
#                 [FastResultMessage.code_to_type.get(coltype, -1) for coltype in coltypes],
#                 dtype=np.dtype('i'))
#
#     rowcount = read_int(reader)
#     # return RowIterator(reader, coltypes, colcodes, protocol_version, rowcount)
#     return [parse_row(reader, coltypes, colcodes, protocol_version)
#                 for i in range(rowcount)]
#
#
# cdef class RowIterator:
#     """
#     Result iterator for a set of rows
#
#     There seems to be an issue with generator expressions + memoryviews, so we
#     have a special iterator class instead.
#     """
#
#     cdef list coltypes
#     cdef int[::1] colcodes
#     cdef Py_ssize_t rowcount, pos
#     cdef BytesIOReader reader
#     cdef object protocol_version
#
#     def __init__(self, reader, coltypes, colcodes, protocol_version, rowcount):
#         self.reader = reader
#         self.coltypes = coltypes
#         self.colcodes = colcodes
#         self.protocol_version = protocol_version
#         self.rowcount = rowcount
#         self.pos = 0
#
#     def __iter__(self):
#         return self
#
#     def __next__(self):
#         if self.pos >= self.rowcount:
#             raise StopIteration
#         self.pos += 1
#         return parse_row(self.reader, self.coltypes, self.colcodes, self.protocol_version)
#
#     next = __next__
#
#
# cdef inline parse_row(BytesIOReader reader, list coltypes, int[::1] colcodes,
#                       protocol_version):
#     cdef Py_ssize_t j
#
#     row = []
#     for j, ctype in enumerate(coltypes):
#         raw_val_size = read_int(reader)
#         if raw_val_size < 0:
#             val = None
#         else:
#             raw_val = reader.read(raw_val_size)
#             val = from_binary(ctype, colcodes[j], raw_val,
#                               raw_val_size, protocol_version)
#         row.append(val)
#
#     return row
#
#
# cdef inline from_binary(cqltype, int typecode, char *byts, int32_t size, protocol_version):
#     """
#     Deserialize a bytestring into a value. See the deserialize() method
#     for more information. This method differs in that if None or the empty
#     string is passed in, None may be returned.
#
#     This method provides a fast-path deserialization routine.
#     """
#     if size == 0 and cqltype.empty_binary_ok:
#         return empty(cqltype)
#     return deserialize(cqltype, typecode, byts, size, protocol_version)
#
#
# cdef empty(cqltype):
#     return EMPTY if cqltype.support_empty_values else None
#
#
# def to_binary(cqltype, val, protocol_version):
#     """
#     Serialize a value into a bytestring. See the serialize() method for
#     more information. This method differs in that if None is passed in,
#     the result is the empty string.
#     """
#     return b'' if val is None else cqltype.serialize(val, protocol_version)
#
# cdef DataType obj = Int64()
#
# cdef deserialize(cqltype, int typecode, char *byts, int32_t size, protocol_version):
#     # if typecode == typecodes.LongType:
#     #     # return int64_unpack(byts)
#     #     return obj.deserialize(byts, size, protocol_version)
#     # else:
#     # return deserialize_generic(cqltype, typecode, byts, size, protocol_version)
#     return cqltype.deserialize(byts[:size], protocol_version)
#
# cdef deserialize_generic(cqltype, int typecode, char *byts, int32_t size,
#         protocol_version):
#     return cqltype.deserialize(byts[:size], protocol_version)
#