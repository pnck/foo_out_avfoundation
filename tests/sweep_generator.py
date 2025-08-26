#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
立体声扫频音频生成器 - 命令行版本
支持WAV和PCM格式输出

使用示例:
python sweep_generator.py -o output.wav -d 10 -fl 20 -fh 20000 --format wav
python sweep_generator.py -o output.pcm -d 5 -fl 100 -fh 8000 --format pcm --log
"""

import argparse
import numpy as np
import wave
import struct
import sys
import os
from scipy.io.wavfile import write

class SweepGenerator:
    def __init__(self):
        self.sample_rate = 44100
        self.bit_depth = 16
        
    def generate_linear_chirp(self, t, f0, f1, duration):
        """生成线性扫频信号"""
        k = (f1 - f0) / duration
        return np.sin(2 * np.pi * (f0 * t + k * t**2 / 2))
    
    def generate_log_chirp(self, t, f0, f1, duration):
        """生成对数扫频信号"""
        if f0 <= 0 or f1 <= 0:
            raise ValueError("对数扫频的频率必须大于0")
        k = np.log(f1 / f0) / duration
        return np.sin(2 * np.pi * f0 * (np.exp(k * t) - 1) / k)
    
    def apply_fade(self, signal, sample_rate, fade_time=0.05):
        """应用渐入渐出效果"""
        fade_samples = int(fade_time * sample_rate)
        if fade_samples * 2 >= len(signal):
            fade_samples = len(signal) // 4
        
        if fade_samples > 0:
            fade_in = np.linspace(0, 1, fade_samples)
            fade_out = np.linspace(1, 0, fade_samples)
            signal[:fade_samples] *= fade_in
            signal[-fade_samples:] *= fade_out
        
        return signal
    
    def generate_sweep(self, duration, start_freq_left, end_freq_left, 
                      start_freq_right, end_freq_right, delay_right=0.0,
                      logarithmic=False, volume=0.8, sample_rate=44100):
        """生成扫频音频数据"""
        self.sample_rate = sample_rate
        
        # 生成时间轴
        t = np.linspace(0, duration, int(sample_rate * duration), False)
        
        # 选择扫频类型
        chirp_func = self.generate_log_chirp if logarithmic else self.generate_linear_chirp
        
        # 生成左声道
        left_channel = chirp_func(t, start_freq_left, end_freq_left, duration)
        
        # 生成右声道（考虑延迟）
        if delay_right > 0:
            t_right = t - delay_right
            t_right = np.where(t_right < 0, 0, t_right)
            right_channel = chirp_func(t_right, start_freq_right, end_freq_right, duration)
            # 延迟部分静音
            silence_samples = int(delay_right * sample_rate)
            if silence_samples > 0:
                right_channel[:silence_samples] = 0
        else:
            right_channel = chirp_func(t, start_freq_right, end_freq_right, duration)
        
        # 应用渐入渐出
        left_channel = self.apply_fade(left_channel, sample_rate)
        right_channel = self.apply_fade(right_channel, sample_rate)
        
        # 调整音量
        left_channel *= volume
        right_channel *= volume
        
        # 合并立体声
        stereo_audio = np.column_stack((left_channel, right_channel))
        
        return stereo_audio
    
    def save_wav(self, audio_data, filename, sample_rate=44100, bit_depth=16):
        """保存为WAV格式"""
        if bit_depth == 16:
            audio_data = np.clip(audio_data, -1.0, 1.0)
            audio_data = (audio_data * 32767).astype(np.int16)
        elif bit_depth == 24:
            audio_data = np.clip(audio_data, -1.0, 1.0)
            audio_data = (audio_data * 8388607).astype(np.int32)
        elif bit_depth == 32:
            audio_data = audio_data.astype(np.float32)
        
        write(filename, sample_rate, audio_data)
        print(f"已保存WAV文件: {filename}")
    
    def save_pcm(self, audio_data, filename, sample_rate=44100, bit_depth=16):
        """保存为PCM格式（原始音频数据）"""
        # 将浮点数据转换为指定位深度的整数
        if bit_depth == 16:
            audio_data = np.clip(audio_data, -1.0, 1.0)
            pcm_data = (audio_data * 32767).astype(np.int16)
            format_char = '<h'  # 小端16位整数
        elif bit_depth == 24:
            audio_data = np.clip(audio_data, -1.0, 1.0)
            pcm_data = (audio_data * 8388607).astype(np.int32)
            # 24位需要特殊处理
            format_char = '<i'
        elif bit_depth == 32:
            pcm_data = audio_data.astype(np.float32)
            format_char = '<f'  # 小端32位浮点
        else:
            raise ValueError(f"不支持的位深度: {bit_depth}")
        
        # 写入PCM文件
        with open(filename, 'wb') as f:
            if bit_depth == 24:
                # 24位特殊处理：每个样本写入3个字节
                for sample in pcm_data.flatten():
                    # 转换为24位（3字节）
                    sample_bytes = struct.pack('<i', sample)[:3]
                    f.write(sample_bytes)
            else:
                # 16位和32位直接写入
                for sample in pcm_data.flatten():
                    f.write(struct.pack(format_char, sample))
        
        print(f"已保存PCM文件: {filename}")
        print(f"PCM参数: {sample_rate}Hz, {bit_depth}bit, 立体声")

def main():
    parser = argparse.ArgumentParser(
        description='生成左右声道扫频音频文件',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
使用示例:
  # 生成10秒WAV格式的上扫频（20Hz-20kHz）
  python sweep_generator.py -o sweep_up.wav -d 10 -l 20 -L 20000
  
  # 生成5秒的下扫频（20kHz-20Hz）
  python sweep_generator.py -o sweep_down.wav -d 5 -l 20000 -L 20
  
  # 生成PCM格式对数扫频
  python sweep_generator.py -o sweep.pcm -d 5 -l 100 -L 8000 -f pcm -g
  
  # 左右声道不同扫频方向
  python sweep_generator.py -o opposite.wav -d 8 -l 50 -L 5000 -r 15000 -R 200
  
  # 右声道延迟2秒开始的上扫频
  python sweep_generator.py -o delay.wav -d 6 -l 100 -L 10000 -D 2.0
  
  # 高质量48kHz/24bit输出
  python sweep_generator.py -o hq.wav -d 5 -l 20 -L 20000 -s 48000 -b 24
        ''')
    
    # 基本参数
    parser.add_argument('-o', '--output', required=True,
                       help='输出文件名')
    parser.add_argument('-d', '--duration', type=float, default=10,
                       help='音频时长（秒），默认10秒')
    parser.add_argument('-f', '--format', choices=['wav', 'pcm'], default='wav',
                       help='输出格式，默认wav')
    
    # 左声道频率参数
    parser.add_argument('-l', '--left-start', type=float, default=20,
                       help='左声道起始频率（Hz），默认20Hz')
    parser.add_argument('-L', '--left-end', type=float, default=20000,
                       help='左声道结束频率（Hz），默认20000Hz')
    
    # 右声道频率参数
    parser.add_argument('-r', '--right-start', type=float,
                       help='右声道起始频率（Hz），默认与左声道相同')
    parser.add_argument('-R', '--right-end', type=float,
                       help='右声道结束频率（Hz），默认与左声道相同')
    
    # 音频参数
    parser.add_argument('-s', '--sample-rate', type=int, default=44100,
                       help='采样率（Hz），默认44100')
    parser.add_argument('-b', '--bit-depth', type=int, choices=[16, 24, 32], default=16,
                       help='位深度，默认16bit')
    parser.add_argument('-v', '--volume', type=float, default=0.8,
                       help='音量（0.0-1.0），默认0.8')
    
    # 扫频类型和效果
    parser.add_argument('-g', '--log', action='store_true',
                       help='使用对数扫频（默认线性扫频）')
    parser.add_argument('-D', '--delay', type=float, default=0.0,
                       help='右声道延迟时间（秒），默认0')
    
    # 解析参数
    args = parser.parse_args()
    
    # 参数验证
    if args.duration <= 0:
        print("错误: 音频时长必须大于0", file=sys.stderr)
        sys.exit(1)
    
    if args.left_start <= 0 or args.left_end <= 0:
        print("错误: 频率必须大于0", file=sys.stderr)
        sys.exit(1)
    
    if args.left_start == args.left_end:
        print("错误: 起始频率和结束频率不能相同", file=sys.stderr)
        sys.exit(1)
    
    if not 0.0 <= args.volume <= 1.0:
        print("错误: 音量必须在0.0到1.0之间", file=sys.stderr)
        sys.exit(1)
    
    # 设置右声道频率（如果未指定则与左声道相同）
    freq_right_start = args.right_start if args.right_start is not None else args.left_start
    freq_right_end = args.right_end if args.right_end is not None else args.left_end
    
    if freq_right_start <= 0 or freq_right_end <= 0:
        print("错误: 右声道频率必须大于0", file=sys.stderr)
        sys.exit(1)
    
    if freq_right_start == freq_right_end:
        print("错误: 右声道起始频率和结束频率不能相同", file=sys.stderr)
        sys.exit(1)
    
    # 创建生成器
    generator = SweepGenerator()
    
    try:
        print("正在生成扫频音频...")
        print(f"时长: {args.duration}秒")
        print(f"采样率: {args.sample_rate}Hz")
        print(f"位深度: {args.bit_depth}bit")
        print(f"扫频类型: {'对数' if args.log else '线性'}")
        left_direction = "上扫频" if args.left_start < args.left_end else "下扫频"
        right_direction = "上扫频" if freq_right_start < freq_right_end else "下扫频"
        print(f"左声道: {args.left_start}Hz → {args.left_end}Hz ({left_direction})")
        print(f"右声道: {freq_right_start}Hz → {freq_right_end}Hz ({right_direction})")
        if args.delay > 0:
            print(f"右声道延迟: {args.delay}秒")
        
        # 生成音频数据
        audio_data = generator.generate_sweep(
            duration=args.duration,
            start_freq_left=args.left_start,
            end_freq_left=args.left_end,
            start_freq_right=freq_right_start,
            end_freq_right=freq_right_end,
            delay_right=args.delay,
            logarithmic=args.log,
            volume=args.volume,
            sample_rate=args.sample_rate
        )
        
        # 保存文件
        if args.format == 'wav':
            generator.save_wav(audio_data, args.output, args.sample_rate, args.bit_depth)
        elif args.format == 'pcm':
            generator.save_pcm(audio_data, args.output, args.sample_rate, args.bit_depth)
        
        # 显示文件信息
        file_size = os.path.getsize(args.output)
        print(f"文件大小: {file_size / 1024 / 1024:.2f} MB")
        print("生成完成!")
        
    except Exception as e:
        print(f"错误: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()