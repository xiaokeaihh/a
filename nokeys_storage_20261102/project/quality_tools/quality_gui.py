"""Local launcher. Actual measurements require the user's native-size captures."""
from pathlib import Path
import os,sys,threading,subprocess
import tkinter as tk
from tkinter import ttk,filedialog,messagebox
ROOT=Path(__file__).resolve().parents[1]
LAB=Path(__file__).with_name('quality_lab.py')
root=tk.Tk();root.title('WYC · 720p画质实验');root.geometry('850x640')
style=ttk.Style();style.configure('.',font=('Microsoft YaHei',10))
image=tk.StringVar();rois=tk.StringVar();output=tk.StringVar(value=str(ROOT/'measurements/experiment_01'));view=tk.StringVar(value='6');layout=tk.StringVar(value='compare');orientation=tk.StringVar(value='hdmi');device=tk.StringVar(value='0')
frame=ttk.Frame(root,padding=18);frame.pack(fill='both',expand=True)
ttk.Label(frame,text='固定条件、保存原尺寸、先测量再优化',font=('Microsoft YaHei',16,'bold')).pack(anchor='w')
ttk.Label(frame,text='基准：1280×720 / 中部水平110°；正式图卡测量需关闭增强和OSD。').pack(anchor='w',pady=(5,15))
def browse_image():
 p=filedialog.askopenfilename(filetypes=[('图像','*.png *.bmp *.tif *.tiff')]);
 if p:image.set(p)
def browse_rois():
 p=filedialog.askopenfilename(filetypes=[('区域配置','*.json')]);
 if p:rois.set(p)
def browse_output():
 p=filedialog.askdirectory();
 if p:output.set(p)
for label,var,fn in [('原尺寸图像',image,browse_image),('区域配置JSON',rois,browse_rois),('结果目录',output,browse_output)]:
 row=ttk.Frame(frame);row.pack(fill='x',pady=4);ttk.Label(row,text=label,width=15).pack(side='left');ttk.Entry(row,textvariable=var).pack(side='left',fill='x',expand=True);ttk.Button(row,text='选择',command=fn).pack(side='left',padx=6)
row=ttk.Frame(frame);row.pack(fill='x',pady=7);ttk.Label(row,text='参考视角').pack(side='left');ttk.Combobox(row,textvariable=view,values=['7','0','1','2','3','4','5','6'],width=5,state='readonly').pack(side='left',padx=8);ttk.Label(row,text='原图方向').pack(side='left');ttk.Combobox(row,textvariable=orientation,values=['hdmi','camera'],width=10,state='readonly').pack(side='left',padx=8);ttk.Label(row,text='hdmi=原图模式截帧；camera=摄像头行顺序').pack(side='left')
row=ttk.Frame(frame);row.pack(fill='x',pady=3);ttk.Label(row,text='测量布局：compare=显示屏对比，padded=软件参考中心单图').pack(side='left');ttk.Combobox(row,textvariable=layout,values=['compare','padded'],width=10,state='readonly').pack(side='left',padx=8)
row=ttk.Frame(frame);row.pack(fill='x',pady=3);ttk.Label(row,text='采集卡设备编号').pack(side='left');ttk.Combobox(row,textvariable=device,values=['0','1','2','3','4'],width=5,state='readonly').pack(side='left',padx=8);ttk.Label(row,text='如打开了笔记本摄像头，关闭后尝试下一个编号；也可用网页选择设备。').pack(side='left')
buttons=[];busy=False
log=tk.Text(frame,height=12,wrap='word',font=('Consolas',10))
def append(s):log.insert('end',s+'\n');log.see('end')
def run(args,needed_image=True):
 global busy
 if busy:return
 if needed_image and not Path(image.get()).is_file():messagebox.showerror('缺少图像','先选择原尺寸1280×720图像');return
 Path(output.get()).mkdir(parents=True,exist_ok=True);busy=True
 for b in buttons:b.configure(state='disabled')
 append('开始：'+args[0])
 def worker():
  env=os.environ.copy();env['PYTHONUTF8']='1'
  p=subprocess.run([sys.executable,'-u',str(LAB),*args],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  def done():
   global busy
   append(p.stdout);append('完成' if p.returncode==0 else '失败：请检查上述原因');busy=False
   for b in buttons:b.configure(state='normal')
  root.after(0,done)
 threading.Thread(target=worker,daemon=True).start()
def select(kind,axis='vertical'):
 path=Path(output.get())/(kind+'_'+axis+'_regions.json');rois.set(str(path));run(['select','--input',image.get(),'--kind',kind,'--orientation',axis,'--out',str(path)])
def measure():
 if not Path(rois.get()).is_file():messagebox.showerror('缺少区域','先选择斜边或网格线区域');return
 run(['measure','--layout',layout.get(),'--input',image.get(),'--rois',rois.get(),'--view',view.get(),'--out',str(Path(output.get())/'measure')])
grid=ttk.Frame(frame);grid.pack(fill='x',pady=10)
actions=[('① 采集卡保存PNG',lambda:run(['capture','--device',device.get(),'--out',str(Path(output.get())/'capture')],False)),('② 选斜边区域',lambda:select('mtf')),('选竖直网格线',lambda:select('line')),('选水平网格线',lambda:select('line','horizontal')),('③ 测量所选区域',measure),('生成测试图参考',lambda:run(['reference','--pattern','--view',view.get(),'--out',str(Path(output.get())/'pattern_reference')],False)),('从原图生成软件参考',lambda:run(['reference','--input',image.get(),'--input-orientation',orientation.get(),'--view',view.get(),'--out',str(Path(output.get())/'reference')])),('同一原图做RTL仿真',lambda:run(['simulate','--input',image.get(),'--input-orientation',orientation.get(),'--view',view.get(),'--out',str(Path(output.get())/'RTL_image_test')]))]
for i,(text,fn) in enumerate(actions):
 b=ttk.Button(grid,text=text,command=fn);b.grid(row=i//4,column=i%4,sticky='ew',padx=3,pady=3);buttons.append(b)
for i in range(4):grid.columnconfigure(i,weight=1)
ttk.Label(frame,text='斜边区域只包含一条边，建议偏离横/竖2–7°；网格线选窄条，避开交点。\n当前测量为工程检查，非认证ISO12233工具；默认按记录亮度测量，不假定相机Gamma。').pack(anchor='w',pady=4)
log.pack(fill='both',expand=True,pady=8)
ttk.Button(frame,text='打开结果目录',command=lambda:os.startfile(output.get()) if Path(output.get()).exists() else None).pack(anchor='e')
root.mainloop()
