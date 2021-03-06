import os
import re
import subprocess
import xml.etree.ElementTree as ET
import signal
import Queue
import threading

from collections import deque, namedtuple

import vim

Ok = namedtuple('Ok', ['val', 'msg'])
Err = namedtuple('Err', ['err'])

Inl = namedtuple('Inl', ['val'])
Inr = namedtuple('Inr', ['val'])

StateId = namedtuple('StateId', ['id'])
Option = namedtuple('Option', ['val'])

OptionState = namedtuple('OptionState', ['sync', 'depr', 'name', 'value'])
OptionValue = namedtuple('OptionValue', ['val'])

Status = namedtuple('Status', ['path', 'proofname', 'allproofs', 'proofnum'])

Goals = namedtuple('Goals', ['fg', 'bg', 'shelved', 'given_up'])
Goal = namedtuple('Goal', ['id', 'hyp', 'ccl'])
Evar = namedtuple('Evar', ['info'])

def parse_response(xml):
    assert xml.tag == 'value'
    if xml.get('val') == 'good':
        return Ok(parse_value(xml[0]), None)
    elif xml.get('val') == 'fail':
        #print('err: %s' % ET.tostring(xml))
        return Err(parse_error(xml))
    else:
        assert False, 'expected "good" or "fail" in <value>'

def parse_value(xml):
    if xml.tag == 'unit':
        return ()
    elif xml.tag == 'bool':
        if xml.get('val') == 'true':
            return True
        elif xml.get('val') == 'false':
            return False
        else:
            assert False, 'expected "true" or "false" in <bool>'
    elif xml.tag == 'string':
        return xml.text or ''
    elif xml.tag == 'int':
        return int(xml.text)
    elif xml.tag == 'state_id':
        return StateId(int(xml.get('val')))
    elif xml.tag == 'list':
        return [parse_value(c) for c in xml]
    elif xml.tag == 'option':
        if xml.get('val') == 'none':
            return Option(None)
        elif xml.get('val') == 'some':
            return Option(parse_value(xml[0]))
        else:
            assert False, 'expected "none" or "some" in <option>'
    elif xml.tag == 'pair':
        return tuple(parse_value(c) for c in xml)
    elif xml.tag == 'union':
        if xml.get('val') == 'in_l':
            return Inl(parse_value(xml[0]))
        elif xml.get('val') == 'in_r':
            return Inr(parse_value(xml[0]))
        else:
            assert False, 'expected "in_l" or "in_r" in <union>'
    elif xml.tag == 'option_state':
        sync, depr, name, value = map(parse_value, xml)
        return OptionState(sync, depr, name, value)
    elif xml.tag == 'option_value':
        return OptionValue(parse_value(xml[0]))
    elif xml.tag == 'status':
        path, proofname, allproofs, proofnum = map(parse_value, xml)
        return Status(path, proofname, allproofs, proofnum)
    elif xml.tag == 'goals':
        return Goals(*map(parse_value, xml))
    elif xml.tag == 'goal':
        return Goal(*map(parse_value, xml))
    elif xml.tag == 'evar':
        return Evar(*map(parse_value, xml))
    elif xml.tag == 'xml' or xml.tag == 'richpp':
        return ''.join(xml.itertext())

def parse_error(xml):
    richpp = xml.find('richpp/_')
    if richpp is None:
        print('ERR: no richpp')
        return ET.fromstring(re.sub(r"<state_id val=\"\d+\" />", '', ET.tostring(xml)))
    return richpp

def build(tag, val=None, children=()):
    attribs = {'val': val} if val is not None else {}
    xml = ET.Element(tag, attribs)
    xml.extend(children)
    return xml

def encode_call(name, arg):
    return build('call', name, [encode_value(arg)])

def encode_value(v):
    if v == ():
        return build('unit')
    elif isinstance(v, bool):
        xml = build('bool', str(v).lower())
        xml.text = str(v)
        return xml
    elif isinstance(v, str) or isinstance(v, unicode):
        xml = build('string')
        xml.text = v
        return xml
    elif isinstance(v, int):
        xml = build('int')
        xml.text = str(v)
        return xml
    elif isinstance(v, StateId):
        return build('state_id', str(v.id))
    elif isinstance(v, list):
        return build('list', None, [encode_value(c) for c in v])
    elif isinstance(v, Option):
        xml = build('option')
        if v.val is not None:
            xml.set('val', 'some')
            xml.append(encode_value(v.val))
        else:
            xml.set('val', 'none')
        return xml
    elif isinstance(v, Inl):
        return build('union', 'in_l', [encode_value(v.val)])
    elif isinstance(v, Inr):
        return build('union', 'in_r', [encode_value(v.val)])
    # NB: `tuple` check must be at the end because it overlaps with () and
    # namedtuples.
    elif isinstance(v, tuple):
        return build('pair', None, [encode_value(c) for c in v])
    else:
        assert False, 'unrecognized type in encode_value: %r' % (type(v),)

class Coqtop(object):
    def __init__(self):
        self.coqtop = None
        self.states = []
        self.state_id = None
        self.root_state = None

    def kill_coqtop(self):
        if self.coqtop:
            try:
                self.coqtop.terminate()
                self.coqtop.communicate()
            except OSError:
                pass
            self.coqtop = None

    def escape(self, cmd):
        return cmd.replace("&nbsp;", ' ') \
                  .replace("&apos;", '\'') \
                  .replace("&#40;", '(') \
                  .replace("&#41;", ')')

    def get_answer(self, response):
        fd = self.coqtop.stdout.fileno()
        data = ''
        while True:
            try:
                data += os.read(fd, 0x4000)
                try:
                    elt = ET.fromstring('<coqtoproot>' + self.escape(data) + '</coqtoproot>')
                    shouldWait = True
                    valueNode = None
                    messageNode = None
                    for c in elt:
                        if c.tag == 'value':
                            shouldWait = False
                            valueNode = c
                        if c.tag == 'message':
                            if messageNode is not None:
                                messageNode = messageNode + "\n\n" + parse_value(c[2])
                            else:
                                messageNode = parse_value(c[2])
                    if shouldWait:
                        continue
                    else:
                        vp = parse_response(valueNode)
                        if messageNode is not None:
                            if isinstance(vp, Ok):
                                response.put(Ok(vp.val, messageNode))
                                return
                        response.put(vp)
                        return
                except ET.ParseError:
                    continue
            except OSError:
                # coqtop died
                response.put(None)
                return

    def call(self, name, arg, encoding='utf-8', use_timeout=False):
        xml = encode_call(name, arg)
        msg = ET.tostring(xml, encoding)
        self.send_cmd(msg)
        response_q = Queue.Queue()
        answer_thread = threading.Thread(target=self.get_answer, args=(response_q,))
        answer_thread.daemon = True
        answer_thread.start()

        if use_timeout:
            timeout = int(vim.eval('b:coq_timeout'))
            if timeout == 0:
                timeout = None
        else:
            timeout = None

        answer_thread.join(timeout)
        try:
            response = response_q.get_nowait()
        except Queue.Empty:
            self.coqtop.send_signal(signal.SIGINT)
            print('Coqtop timed out. You can change the timeout with <leader>ct and try again.')
            response = Err('timeout')

        return response

    def send_cmd(self, cmd):
        self.coqtop.stdin.write(cmd)

    def restart_coq(self, *args):
        if self.coqtop: self.kill_coqtop()
        options = [ 'coqtop'
                  , '-ideslave'
                  , '-main-channel'
                  , 'stdfds'
                  , '-async-proofs'
                  , 'on'
                  ]
        try:
            if os.name == 'nt':
                self.coqtop = subprocess.Popen(
                    options + list(args)
                  , stdin = subprocess.PIPE
                  , stdout = subprocess.PIPE
                  , stderr = subprocess.STDOUT
                )
            else:
                with open(os.devnull, 'w') as null:
                    self.coqtop = subprocess.Popen(
                            options + list(args)
                            , stdin = subprocess.PIPE
                            , stdout = subprocess.PIPE
                            , stderr = null
                            )
                    self.coqtop.stderr = None

            r = self.call('Init', Option(None), use_timeout=True)
            assert isinstance(r, Ok)
            self.root_state = r.val
            self.state_id = r.val
            return True
        except (OSError, AssertionError):
            print("Error: couldn't launch coqtop")
            return False

    def launch_coq(self, *args):
        return self.restart_coq(*args)

    def cur_state(self):
        if len(self.states) == 0:
            return self.root_state
        else:
            return self.state_id

    # TODO: allow timeout
    def advance(self, cmd, encoding = 'utf-8'):
        r = self.call('Add', ((cmd.decode(encoding), -1), (self.cur_state(), True)), encoding, use_timeout=False)
        if r is None or isinstance(r, Err):
            return r
        g = self.goals()
        if isinstance(g, Err):
            return g
        self.states.append(self.state_id)
        self.state_id = r.val[0]
        return r

    # TODO: assert fails if rewind called right after launching
    def rewind(self, step = 1):
        assert step <= len(self.states)
        idx = len(self.states) - step
        self.state_id = self.states[idx]
        self.states = self.states[0:idx]
        return self.call('Edit_at', self.state_id)

    def query(self, cmd, encoding = 'utf-8'):
        r = self.call('Query', (cmd.decode(encoding), self.cur_state()), encoding, use_timeout=True)
        return r

    def goals(self):
        return self.call('Goal', ())

    def read_states(self):
        return self.states
