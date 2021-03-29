class AsDictMixin:
    @classmethod
    def as_dict(cls, self):
        result = {}
        if not isinstance(self, AsDictMixin):
            # not a structure, assume it's already a python object
            return self
        if not hasattr(cls, "_fields_"):
            return result
        # sys.version_info >= (3, 5)
        # for (field, *_) in cls._fields_:  # noqa
        for field_tuple in cls._fields_:  # noqa
            field = field_tuple[0]
            if field.startswith('PADDING_'):
                continue
            value = getattr(self, field)
            type_ = type(value)
            if hasattr(value, "_length_") and hasattr(value, "_type_"):
                # array
                if not hasattr(type_, "as_dict"):
                    value = [v for v in value]
                else:
                    type_ = type_._type_
                    value = [type_.as_dict(v) for v in value]
            elif hasattr(value, "contents") and hasattr(value, "_type_"):
                # pointer
                try:
                    if not hasattr(type_, "as_dict"):
                        value = value.contents
                    else:
                        type_ = type_._type_
                        value = type_.as_dict(value.contents)
                except ValueError:
                    # nullptr
                    value = None
            elif isinstance(value, AsDictMixin):
                # other structure
                value = type_.as_dict(value)
            result[field] = value
        return result


class IStructureUnion(object):
    @classmethod
    def _field_names_(cls):
        if hasattr(cls, '_fields_'):
            return (f[0] for f in cls._fields_ if not f[0].startswith('PADDING'))
        else:
            return ()

    @classmethod
    def get_type(cls, field):
        for f in cls._fields_:
            if f[0] == field:
                return f[1]
        return None

    def __str__(self, padding=''):
        cls = self.__class__
        str_out = '[' + cls.__name__ + ']' + '\n'
        field_names = list(cls._field_names_())
        field_count = len(field_names)
        for (i, field_name) in enumerate(field_names):
            is_last = (i == field_count - 1)
            str_out += padding
            str_out += '└╴' if is_last else '├╴'
            str_out += field_name + ': '
            attr = getattr(self, field_name)
            if isinstance(attr, (Union, Structure)):
                padding_next = padding + ('   ' if is_last else '│  ')
                str_out += attr.__str__(padding_next)
            elif isinstance(attr, int):
                # is boolean bitfield ?
                # https://stackoverflow.com/a/23135252/1641819
                attr_cls = getattr(cls, field_name)
                if hasattr(attr_cls, 'size') and attr_cls.size >> 16 == 1:
                    # Print as boolean
                    str_out += str(bool(attr)) + '\n'
                else:
                    # Print as hex integer
                    str_out += f'{attr:#04x}\n'
                # end else
            else:
                str_out += attr.__str__() + '\n'
        return str_out

    def str_raw_memory(self):
        return '[' + ' '.join(f'{byte:02x}' for byte in bytes(self)) + ']'


class Structure(ctypes.Structure, IStructureUnion, AsDictMixin):

    def __init__(self, *args, **kwds):
        # We don't want to use positional arguments fill PADDING_* fields
        args = dict(zip(self.__class__._field_names_(), args))
        args.update(kwds)
        super(Structure, self).__init__(**args)

    @classmethod
    def bind(cls, bound_fields):
        fields = {}
        for name, type_ in cls._fields_:
            if hasattr(type_, "restype"):
                if name in bound_fields:
                    # use a closure to capture the callback from the loop scope
                    fields[name] = (
                        type_((lambda callback: lambda *args: callback(*args))(
                            bound_fields[name]))
                    )
                    del bound_fields[name]
                else:
                    # default callback implementation (does nothing)
                    try:
                        default_ = type_(0).restype().value
                    except TypeError:
                        default_ = None
                    fields[name] = type_((
                        lambda default_: lambda *args: default_)(default_))
            else:
                # not a callback function, use default initialization
                if name in bound_fields:
                    fields[name] = bound_fields[name]
                    del bound_fields[name]
                else:
                    fields[name] = type_()
        if len(bound_fields) != 0:
            raise ValueError(
                "Cannot bind the following unknown callback(s) {}.{}".format(
                    cls.__name__, bound_fields.keys()
            ))
        return cls(**fields)


class Union(ctypes.Union, IStructureUnion, AsDictMixin):

    def __init__(self, *args, **kwds):
        # We don't want to use positional arguments fill PADDING_* fields
        args = dict(zip(self.__class__._field_names_(), args))
        args.update(kwds)
        super(Union, self).__init__(**args)
